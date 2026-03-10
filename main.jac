"""MCP Playground Backend + Frontend entry point."""

# ──────────────────────────────────────────────
# Backend: LLM call walker for agentic mode
# Single-turn LLM API call via litellm
# ──────────────────────────────────────────────

walker:pub llm_call {
    has model: str = "gpt-4o-mini",
        api_key: str = "",
        provider: str = "openai",
        messages: list = [],
        tools: list = [],
        temperature: float = 0.7,
        max_tokens: int = 4096;

    can call_llm with Root entry {
        import json;

        # Convert MCP tool schemas to OpenAI function-calling format
        # MCP:    {name, description, inputSchema: {type, properties, required}}
        # OpenAI: {type: "function", function: {name, description, parameters: ...}}
        openai_tools = [];
        for mcp_tool in self.tools {
            openai_tools.append({
                "type": "function",
                "function": {
                    "name": mcp_tool.get("name", ""),
                    "description": mcp_tool.get("description", ""),
                    "parameters": mcp_tool.get("inputSchema", {"type": "object", "properties": {}})
                }
            });
        }

        try {
            import litellm;
            litellm.drop_params = True;

            # Build model string with provider prefix for litellm routing
            model_str = self.model;
            if self.provider == "anthropic" and not self.model.startswith("anthropic/") {
                model_str = f"anthropic/{self.model}";
            } elif self.provider == "groq" and not self.model.startswith("groq/") {
                model_str = f"groq/{self.model}";
            } elif self.provider == "together" and not self.model.startswith("together_ai/") {
                model_str = f"together_ai/{self.model}";
            }

            kwargs: dict = {
                "model": model_str,
                "messages": self.messages,
                "temperature": self.temperature,
                "max_tokens": self.max_tokens,
                "api_key": self.api_key
            };

            if len(openai_tools) > 0 {
                kwargs["tools"] = openai_tools;
                kwargs["tool_choice"] = "auto";
            }

            response = litellm.completion(**kwargs);

            # Extract response into serializable format
            choice = response.choices[0];
            message = choice.message;

            result: dict = {
                "role": "assistant",
                "content": message.content or "",
                "tool_calls": None,
                "finish_reason": choice.finish_reason,
                "usage": {
                    "prompt_tokens": response.usage.prompt_tokens if response.usage else 0,
                    "completion_tokens": response.usage.completion_tokens if response.usage else 0,
                    "total_tokens": response.usage.total_tokens if response.usage else 0
                },
                "model": response.model or self.model
            };

            # Extract tool calls if present
            if message.tool_calls and len(message.tool_calls) > 0 {
                tc_list = [];
                for tc in message.tool_calls {
                    args_str = tc.function.arguments if isinstance(tc.function.arguments, str) else json.dumps(tc.function.arguments);
                    tc_list.append({
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": args_str
                        }
                    });
                }
                result["tool_calls"] = tc_list;
            }

            report {"ok": True, "data": result};

        } except Exception as e {
            import traceback;
            print(f"[llm_call] Error: {traceback.format_exc()}");
            report {"ok": False, "error": str(e)};
        }
    }
}

# ──────────────────────────────────────────────
# Backend: Server-side agentic loop walker
# Runs the full LLM ↔ MCP tool-call loop in one
# round-trip. Eliminates N frontend round-trips.
# mcp_servers: [{url, transport, authHeaders, sessionId, tools}]
# ──────────────────────────────────────────────

walker:pub agent_run {
    has messages: list = [],
        mcp_servers: list = [],
        model: str = "gpt-4o-mini",
        provider: str = "openai",
        api_key: str = "",
        temperature: float = 0.7,
        max_tokens: int = 4096,
        max_iterations: int = 10;

    can run with Root entry {
        import litellm;
        import json;
        import urllib.request;
        import urllib.error;
        import traceback;

        litellm.drop_params = True;

        # ── Helper: call a single MCP tool synchronously ──
        def call_mcp_tool(server: dict, tool_name: str, tool_args: dict) -> dict {
            rpc_body = json.dumps({
                "jsonrpc": "2.0",
                "id": f"agent_{tool_name}",
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": tool_args}
            }).encode("utf-8");

            req_headers = {
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "User-Agent": "Mozilla/5.0 MCP-Playground-Agent/1.0"
            };
            for k in (server.get("authHeaders") or {}) {
                req_headers[k] = server["authHeaders"][k];
            }
            sid = server.get("sessionId");
            if sid {
                req_headers["mcp-session-id"] = sid;
            }

            req = urllib.request.Request(
                server["url"], data=rpc_body, headers=req_headers, method="POST"
            );
            try {
                with urllib.request.urlopen(req, timeout=30) as resp {
                    ct = resp.headers.get("Content-Type", "");
                    if "text/event-stream" in ct {
                        for _ in range(2000) {
                            raw = resp.readline();
                            if not raw { break; }
                            line = raw.decode("utf-8", errors="replace").rstrip("\r\n");
                            if line.startswith("data:") {
                                data_str = line[5:].strip();
                                if data_str and data_str != "[DONE]" {
                                    parsed = json.loads(data_str);
                                    return parsed.get("result", parsed);
                                }
                            }
                        }
                        return {"error": "SSE stream returned no tool result"};
                    } else {
                        raw = resp.read().decode("utf-8");
                        parsed = json.loads(raw);
                        # JSON-RPC result is nested under "result"
                        return parsed.get("result", parsed);
                    }
                }
            } except urllib.error.HTTPError as e {
                err_body = e.read().decode("utf-8") if e.fp else "";
                return {"error": f"HTTP {e.code}: {err_body[:200]}"};
            } except Exception as e {
                return {"error": str(e)};
            }
        }

        # ── Build model string ──
        model_str = self.model;
        if self.provider == "anthropic" and not self.model.startswith("anthropic/") {
            model_str = f"anthropic/{self.model}";
        } elif self.provider == "groq" and not self.model.startswith("groq/") {
            model_str = f"groq/{self.model}";
        } elif self.provider == "together" and not self.model.startswith("together_ai/") {
            model_str = f"together_ai/{self.model}";
        }

        # ── Build tool registry + OpenAI-format tool schemas ──
        tool_registry = {};
        openai_tools = [];
        for server in self.mcp_servers {
            for mcp_tool in server.get("tools", []) {
                name = mcp_tool.get("name", "");
                if name and name not in tool_registry {
                    tool_registry[name] = server;
                    openai_tools.append({
                        "type": "function",
                        "function": {
                            "name": name,
                            "description": mcp_tool.get("description", ""),
                            "parameters": mcp_tool.get("inputSchema", {"type": "object", "properties": {}})
                        }
                    });
                }
            }
        }

        # ── Agentic loop ──
        messages = list(self.messages);
        trace = [];
        total_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0};

        try {
            for iteration in range(1, self.max_iterations + 1) {
                kwargs: dict = {
                    "model": model_str,
                    "messages": messages,
                    "temperature": self.temperature,
                    "max_tokens": self.max_tokens,
                    "api_key": self.api_key
                };
                if len(openai_tools) > 0 {
                    kwargs["tools"] = openai_tools;
                    kwargs["tool_choice"] = "auto";
                }

                response = litellm.completion(**kwargs);
                choice = response.choices[0];
                msg = choice.message;

                if response.usage {
                    total_usage["prompt_tokens"] += response.usage.prompt_tokens or 0;
                    total_usage["completion_tokens"] += response.usage.completion_tokens or 0;
                    total_usage["total_tokens"] += response.usage.total_tokens or 0;
                }

                # Check for tool calls
                if msg.tool_calls and len(msg.tool_calls) > 0 {
                    tc_list = [];
                    for tc in msg.tool_calls {
                        args_str = tc.function.arguments if isinstance(tc.function.arguments, str) else json.dumps(tc.function.arguments);
                        tc_list.append({
                            "id": tc.id,
                            "type": "function",
                            "function": {"name": tc.function.name, "arguments": args_str}
                        });
                    }
                    messages.append({"role": "assistant", "content": msg.content or "", "tool_calls": tc_list});

                    trace.append({
                        "type": "llm_response",
                        "iteration": iteration,
                        "content": msg.content,
                        "finish_reason": choice.finish_reason,
                        "tool_calls": tc_list,
                        "usage": {
                            "prompt_tokens": response.usage.prompt_tokens if response.usage else 0,
                            "completion_tokens": response.usage.completion_tokens if response.usage else 0,
                            "total_tokens": response.usage.total_tokens if response.usage else 0
                        }
                    });

                    # Execute each tool via the originating MCP server
                    for tc in msg.tool_calls {
                        tool_name = tc.function.name;
                        tool_args = {};
                        try {
                            raw_args = tc.function.arguments;
                            tool_args = json.loads(raw_args) if isinstance(raw_args, str) else (raw_args or {});
                        } except Exception {}

                        server = tool_registry.get(tool_name);
                        if server {
                            tool_result = call_mcp_tool(server, tool_name, tool_args);
                        } else {
                            tool_result = {"error": f"Tool '{tool_name}' not found in any connected MCP server"};
                        }

                        trace.append({
                            "type": "tool_result",
                            "iteration": iteration,
                            "tool_name": tool_name,
                            "tool_args": tool_args,
                            "result": tool_result
                        });

                        messages.append({
                            "role": "tool",
                            "tool_call_id": tc.id,
                            "content": json.dumps(tool_result)
                        });
                    }
                    # Loop continues — send updated messages back to LLM

                } else {
                    # No tool calls — final text response, exit loop
                    trace.append({
                        "type": "final_response",
                        "iteration": iteration,
                        "content": msg.content,
                        "finish_reason": choice.finish_reason
                    });
                    report {
                        "ok": True,
                        "final_content": msg.content or "",
                        "messages": messages,
                        "trace": trace,
                        "usage": total_usage,
                        "iterations": iteration
                    };
                    return;
                }
            }

            # Max iterations hit without final response
            report {
                "ok": False,
                "error": f"Max iterations ({self.max_iterations}) reached without a final response",
                "messages": messages,
                "trace": trace,
                "usage": total_usage,
                "iterations": self.max_iterations
            };

        } except Exception as e {
            print(f"[agent_run] Error: {traceback.format_exc()}");
            report {"ok": False, "error": str(e), "trace": trace, "usage": total_usage};
        }
    }
}

# ──────────────────────────────────────────────
# Backend: CORS proxy walker for MCP requests
# Forwards JSON-RPC calls to any MCP server URL
# ──────────────────────────────────────────────

walker:pub mcp_proxy {
    has url: str,
        body: dict = {},
        headers: dict = {},
        transport: str = "streamable-http";

    can proxy with Root entry {
        import urllib.request;
        import urllib.parse;
        import json;
        import urllib.error;

        request_headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream"
        };

        for key in self.headers {
            request_headers[key] = self.headers[key];
        }

        print(f"[mcp_proxy] method={self.body.get('method','?')} transport={self.transport}");

        # Use explicit transport mode instead of URL auto-detection
        parsed_url = urllib.parse.urlparse(self.url);
        is_sse = self.transport == "sse";

        post_url = self.url;
        sse_error = None;

        if is_sse {
            # SSE Transport: GET the /sse endpoint first to receive the session POST URL
            try {
                sse_headers = {
                    "Accept": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "User-Agent": request_headers["User-Agent"]
                };
                for key in self.headers {
                    sse_headers[key] = self.headers[key];
                }
                get_req = urllib.request.Request(self.url, headers=sse_headers, method="GET");
                endpoint_url = None;
                with urllib.request.urlopen(get_req, timeout=10) as sse_conn {
                    event_type = "";
                    for _ in range(200) {
                        raw_line = sse_conn.readline();
                        if not raw_line { break; }
                        line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n");
                        if line.startswith("event:") {
                            event_type = line[6:].strip();
                        } elif line.startswith("data:") and event_type == "endpoint" {
                            path = line[5:].strip();
                            if path {
                                endpoint_url = path if path.startswith("http") else f"{parsed_url.scheme}://{parsed_url.netloc}{path}";
                                break;
                            }
                        } elif line == "" {
                            event_type = "";
                        }
                    }
                }
                if endpoint_url {
                    post_url = endpoint_url;
                } else {
                    sse_error = "SSE server did not send an endpoint URL. Try the /mcp endpoint instead.";
                }
            } except Exception as e {
                sse_error = f"SSE session setup failed: {str(e)}. Try the /mcp endpoint instead.";
            }
        }

        if sse_error {
            report {"ok": False, "status": 0, "error": sse_error, "body": ""};
        } else {
            req_body = json.dumps(self.body).encode("utf-8");
            req = urllib.request.Request(post_url, data=req_body, headers=request_headers, method="POST");

            try {
                with urllib.request.urlopen(req, timeout=30) as resp {
                    content_type = resp.headers.get("Content-Type", "");

                    # Capture session ID from response headers (MCP Streamable HTTP transport)
                    session_id = resp.headers.get("mcp-session-id", "");

                    if "text/event-stream" in content_type {
                        # Read SSE line-by-line; stop after first complete event (blank line)
                        events = [];
                        try {
                            for _ in range(1000) {
                                raw_line = resp.readline();
                                if not raw_line { break; }
                                line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n");
                                if line.startswith("data:") {
                                    data_str = line[5:].strip();
                                    if data_str and data_str != "[DONE]" {
                                        try {
                                            events.append(json.loads(data_str));
                                        } except Exception {
                                            events.append({"raw": data_str});
                                        }
                                    }
                                }
                                # SSE event separator — stop once we have data
                                if events and line == "" {
                                    break;
                                }
                            }
                        } except Exception as loop_e {
                            print(f"[mcp_proxy] readline loop exception: {loop_e}");
                        }

                        if events {
                            report {"ok": True, "streaming": True, "events": events, "sessionId": session_id};
                        } else {
                            report {"ok": False, "status": 0, "error": "SSE stream returned no events.", "body": ""};
                        }
                    } else {
                        raw = resp.read().decode("utf-8");
                        if raw.strip() {
                            try {
                                report {"ok": True, "streaming": False, "data": json.loads(raw), "sessionId": session_id};
                            } except Exception {
                                report {"ok": True, "streaming": False, "data": {"raw": raw}, "sessionId": session_id};
                            }
                        } else {
                            report {"ok": False, "status": 0, "error": "Server returned empty body.", "body": ""};
                        }
                    }
                }
            } except urllib.error.HTTPError as e {
                if e.code in (301, 302, 307, 308) {
                    redirect_url = e.headers.get("Location", "");
                    hint = f" Try: {redirect_url}" if redirect_url else " Try adding a trailing slash to the URL.";
                    report {"ok": False, "status": e.code, "error": f"Server redirected the request.{hint}", "body": ""};
                } else {
                    err_body = e.read().decode("utf-8") if e.fp else "";
                    report {"ok": False, "status": e.code, "error": str(e), "body": err_body};
                }
            } except urllib.error.URLError as e {
                report {"ok": False, "status": 0, "error": str(e.reason), "body": ""};
            } except Exception as e {
                report {"ok": False, "status": 0, "error": str(e), "body": ""};
            }
        }
    }
}

# ──────────────────────────────────────────────
# Frontend entry: file-based routing via pages/
# ──────────────────────────────────────────────

cl import ".styles/globals.css";
cl import from "react" { useEffect }

cl {
    def:pub app(children: Any = None) -> Any {
        # Apply dark mode by default
        useEffect(lambda -> Any {
            if not document.documentElement.classList.contains("dark") and not document.documentElement.classList.contains("light") {
                document.documentElement.classList.add("dark");
            }
            return lambda -> None {};
        }, []);

        return <div className="min-h-screen bg-background text-foreground">{children}</div>;
    }
}

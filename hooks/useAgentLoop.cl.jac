"""useAgentLoop – drives the LLM agentic loop from the frontend.

Two modes:
  perTurn    – one llm_call walker per iteration (full observability, default)
  serverSide – single agent_run walker handles the full loop on the backend

Both modes support:
  - Multi-server tool aggregation (tools from ALL connected servers)
  - Per-tool routing to the correct MCP server
  - Tool allowlist filtering (llmConfig.enabledTools)
  - Confirmation gate (llmConfig.confirmMode)
  - Structured error classification
"""

sv import from ..main { llm_call, agent_run }
cl import from ..store.mcp_store { useMcpStore }
cl import from ..hooks.useMcpClient { useMcpClient }

cl {
    # Module-level abort flag — mutated synchronously, checked in async loop.
    glob _abortFlag: Any = {"aborted": False};

    # Confirmation gate — resolve fn stored here, awaited in runAgentLoop.
    glob _confirmResolve: Any = {"fn": None};

    # ── Auth header builder (mirrors useMcpClient) ──────────────────────────
    def buildAuthHeaders(auth: Any) -> Any {
        h = {};
        if not auth { return h; }
        if auth.type == "bearer" and auth.value {
            h.Authorization = "Bearer " + auth.value;
        } elif auth.type == "apikey" and auth.value {
            key_name = auth.headerName or "X-API-Key";
            h[key_name] = auth.value;
        } elif auth.type == "basic" and auth.value {
            h.Authorization = "Basic " + auth.value;
        }
        return h;
    }

    # ── Report extraction helper ─────────────────────────────────────────────
    def extractReport(result: Any) -> Any {
        if result and result.reports and len(result.reports) > 0 {
            inner = result.reports[0];
            return inner[0] if inner and Array.isArray(inner) and len(inner) > 0 else inner;
        }
        return None;
    }

    # ── Error classifier ─────────────────────────────────────────────────────
    def classifyError(errMsg: str) -> str {
        lower = errMsg.toLowerCase();
        if lower.includes("context_length") or lower.includes("maximum context") or lower.includes("too long") {
            return "context_length";
        }
        if lower.includes("rate_limit") or lower.includes("rate limit") or lower.includes("429") {
            return "rate_limit";
        }
        if lower.includes("api_key") or lower.includes("invalid key") or lower.includes("unauthorized") or lower.includes("401") {
            return "auth";
        }
        if lower.includes("model_not_found") or lower.includes("no such model") {
            return "model_not_found";
        }
        return "generic";
    }

    def friendlyError(errMsg: str) -> str {
        kind = classifyError(errMsg);
        if kind == "context_length" { return "Context window full — clear chat history to continue."; }
        if kind == "rate_limit" { return "Rate limited by the API — wait a moment, then retry."; }
        if kind == "auth" { return "Invalid API key — check your key in LLM Config."; }
        if kind == "model_not_found" { return "Model not found — verify the model name in LLM Config."; }
        return errMsg;
    }

    # ── Hook ────────────────────────────────────────────────────────────────

    def:pub useAgentLoop -> Any {
        connections    = useMcpStore(lambda(s: Any) -> Any { return s.connections; });
        addChatMessage = useMcpStore(lambda(s: Any) -> Any { return s.addChatMessage; });
        setAgentRunning = useMcpStore(lambda(s: Any) -> Any { return s.setAgentRunning; });
        addAgentTraceEvent = useMcpStore(lambda(s: Any) -> Any { return s.addAgentTraceEvent; });
        addTokenUsage  = useMcpStore(lambda(s: Any) -> Any { return s.addTokenUsage; });
        llmConfig      = useMcpStore(lambda(s: Any) -> Any { return s.llmConfig; });
        chatMessages   = useMcpStore(lambda(s: Any) -> Any { return s.chatMessages; });
        setPendingConfirmation = useMcpStore(lambda(s: Any) -> Any { return s.setPendingConfirmation; });

        client = useMcpClient();

        # ── Tool aggregation ─────────────────────────────────────────────────
        # Returns {allTools, toolRegistry} across all connected servers,
        # respecting enabledTools allowlist if set.
        def aggregateTools -> Any {
            toolRegistry = {};
            allTools = [];
            enabledTools = llmConfig.enabledTools;

            connectedConns = connections.filter(
                lambda(c: Any) -> Any { return c.status == "connected"; }
            );

            for conn in connectedConns {
                caps = conn.capabilities or {};
                mcpTools = caps.tools or [];
                for tool in mcpTools {
                    toolName = tool.name;
                    if not toolName { continue; }
                    # Apply allowlist filter
                    if enabledTools != None and not enabledTools.includes(toolName) {
                        continue;
                    }
                    # First server wins on name collision
                    if not (toolName in toolRegistry) {
                        toolRegistry[toolName] = conn;
                        allTools.push(Object.assign({}, tool, {
                            "_serverId": conn.id,
                            "_serverName": conn.name
                        }));
                    }
                }
            }
            return {"allTools": allTools, "toolRegistry": toolRegistry};
        }

        # ── Confirmation gate ────────────────────────────────────────────────
        async def maybeConfirm(tc: Any, toolName: str, toolArgs: Any, serverName: str) -> Any {
            if not llmConfig.confirmMode { return True; }

            # Reflect.construct is the idiomatic Jac way to call `new ClassName(...)`.
            confirmed = await Reflect.construct(Promise, [lambda(resolve: Any) -> None {
                _confirmResolve.fn = resolve;
                setPendingConfirmation({
                    "id": tc.id,
                    "toolName": toolName,
                    "toolArgs": toolArgs,
                    "serverName": serverName
                });
            }]);
            setPendingConfirmation(None);
            _confirmResolve.fn = None;
            return confirmed;
        }

        # ────────────────────────────────────────────────────────────────────
        # Mode A: Per-turn loop (full frontend observability)
        # ────────────────────────────────────────────────────────────────────
        async def runPerTurnLoop(activeConnection: Any, userMessage: str) -> None {
            agg = aggregateTools();
            allTools    = agg.allTools;
            toolRegistry = agg.toolRegistry;

            # Build message history
            messages = [];
            if llmConfig.systemPrompt {
                messages.push({"role": "system", "content": llmConfig.systemPrompt});
            }
            for msg in chatMessages {
                if msg.role != "system" {
                    cleanMsg = {"role": msg.role, "content": msg.content or ""};
                    if msg.tool_calls { cleanMsg.tool_calls = msg.tool_calls; }
                    if msg.tool_call_id { cleanMsg.tool_call_id = msg.tool_call_id; }
                    messages.push(cleanMsg);
                }
            }

            userMsg = {"role": "user", "content": userMessage};
            messages.push(userMsg);
            addChatMessage(userMsg);
            addAgentTraceEvent({"type": "user_message", "timestamp": Date.now(), "data": {"content": userMessage}});

            iteration = 0;
            maxIter   = llmConfig.maxIterations or 10;

            while iteration < maxIter {
                if _abortFlag.aborted { break; }
                iteration = iteration + 1;

                addAgentTraceEvent({
                    "type": "llm_call_start",
                    "timestamp": Date.now(),
                    "data": {"model": llmConfig.model, "iteration": iteration, "toolCount": len(allTools)}
                });

                shouldBreak = False;
                llmData = None;
                try {
                    result = await root spawn llm_call(
                        model=llmConfig.model,
                        api_key=llmConfig.apiKey,
                        messages=messages,
                        tools=allTools,
                        temperature=llmConfig.temperature or 0.7,
                        max_tokens=llmConfig.maxTokens or 4096,
                        provider=llmConfig.provider or "openai"
                    );

                    resp = extractReport(result);

                    if not resp or not resp.ok {
                        errMsg = friendlyError(resp.error if resp else "No response from LLM");
                        addChatMessage({"role": "system", "content": errMsg, "errorKind": classifyError(resp.error if resp else "")});
                        addAgentTraceEvent({"type": "error", "timestamp": Date.now(), "data": {"error": resp.error if resp else "no_response"}});
                        shouldBreak = True;
                    } else {
                        llmData = resp.data;
                    }
                } except Exception as e {
                    errMsg = friendlyError(String(e));
                    addChatMessage({"role": "system", "content": errMsg, "errorKind": classifyError(String(e))});
                    addAgentTraceEvent({"type": "error", "timestamp": Date.now(), "data": {"error": String(e)}});
                    shouldBreak = True;
                }

                if shouldBreak { break; }
                if not llmData { break; }

                if llmData.usage {
                    addTokenUsage(llmData.usage);
                }

                addAgentTraceEvent({
                    "type": "llm_response",
                    "timestamp": Date.now(),
                    "data": {
                        "content": llmData.content,
                        "tool_calls": llmData.tool_calls,
                        "finish_reason": llmData.finish_reason,
                        "usage": llmData.usage,
                        "model": llmData.model,
                        "iteration": iteration
                    }
                });

                if llmData.tool_calls and len(llmData.tool_calls) > 0 {
                    assistantMsg = {
                        "role": "assistant",
                        "content": llmData.content or "",
                        "tool_calls": llmData.tool_calls
                    };
                    messages.push(assistantMsg);
                    addChatMessage(assistantMsg);

                    for tc in llmData.tool_calls {
                        if _abortFlag.aborted { break; }

                        toolName = tc.function.name;
                        toolArgs = {};
                        try { toolArgs = JSON.parse(tc.function.arguments); } except Exception { toolArgs = {}; }

                        # Route to the correct server
                        targetConn = toolRegistry[toolName] if toolName in toolRegistry else activeConnection;
                        serverName = targetConn.name if targetConn else "unknown";

                        addAgentTraceEvent({
                            "type": "tool_call",
                            "timestamp": Date.now(),
                            "data": {
                                "id": tc.id,
                                "name": toolName,
                                "arguments": toolArgs,
                                "server": serverName,
                                "iteration": iteration
                            }
                        });

                        # Confirmation gate
                        approved = await maybeConfirm(tc, toolName, toolArgs, serverName);
                        if not approved {
                            toolContent = JSON.stringify({"denied": True, "reason": "User denied this tool call"});
                            addAgentTraceEvent({
                                "type": "tool_result",
                                "timestamp": Date.now(),
                                "data": {"id": tc.id, "name": toolName, "result": toolContent, "denied": True, "iteration": iteration}
                            });
                            messages.push({"role": "tool", "tool_call_id": tc.id, "content": toolContent});
                            addChatMessage({"role": "tool", "tool_call_id": tc.id, "content": toolContent, "denied": True});
                            continue;
                        }

                        toolContent = "";
                        try {
                            toolResp = await client.callTool(targetConn, toolName, toolArgs);
                            if toolResp and toolResp.result {
                                toolContent = JSON.stringify(toolResp.result);
                            } elif toolResp and toolResp.error {
                                toolContent = JSON.stringify({"error": toolResp.error});
                            } else {
                                toolContent = JSON.stringify(toolResp or {"error": "Empty response"});
                            }
                        } except Exception as e {
                            toolContent = JSON.stringify({"error": String(e)});
                        }

                        addAgentTraceEvent({
                            "type": "tool_result",
                            "timestamp": Date.now(),
                            "data": {"id": tc.id, "name": toolName, "result": toolContent, "server": serverName, "iteration": iteration}
                        });

                        toolMsg = {"role": "tool", "tool_call_id": tc.id, "content": toolContent};
                        messages.push(toolMsg);
                        addChatMessage(toolMsg);
                    }

                } else {
                    finalMsg = {"role": "assistant", "content": llmData.content or ""};
                    messages.push(finalMsg);
                    addChatMessage(finalMsg);
                    addAgentTraceEvent({
                        "type": "final_response",
                        "timestamp": Date.now(),
                        "data": {"content": llmData.content, "iteration": iteration}
                    });
                    break;
                }
            }

            if iteration >= maxIter and not _abortFlag.aborted {
                addChatMessage({"role": "system", "content": f"Agent stopped after {maxIter} iterations."});
                addAgentTraceEvent({"type": "error", "timestamp": Date.now(), "data": {"error": "Max iterations reached", "iterations": maxIter}});
            }
            if _abortFlag.aborted {
                addChatMessage({"role": "system", "content": "Agent loop aborted."});
                addAgentTraceEvent({"type": "error", "timestamp": Date.now(), "data": {"error": "Aborted by user"}});
            }
        }

        # ────────────────────────────────────────────────────────────────────
        # Mode B: Server-side loop (one round-trip, backend runs full loop)
        # ────────────────────────────────────────────────────────────────────
        async def runServerSideLoop(activeConnection: Any, userMessage: str) -> None {
            agg = aggregateTools();
            allTools    = agg.allTools;
            toolRegistry = agg.toolRegistry;

            # Build mcp_servers list with auth + session info per connection
            serverMap = {};
            for toolName in Object.keys(toolRegistry) {
                conn = toolRegistry[toolName];
                if not (conn.id in serverMap) {
                    serverMap[conn.id] = {
                        "url": conn.url,
                        "transport": conn.transport or "streamable-http",
                        "authHeaders": buildAuthHeaders(conn.auth or {}),
                        "sessionId": conn.sessionId or "",
                        "tools": []
                    };
                }
                # Find the raw tool (without _serverId/_serverName tags)
                caps = conn.capabilities or {};
                for rawTool in (caps.tools or []) {
                    if rawTool.name == toolName {
                        serverMap[conn.id].tools.push(rawTool);
                        break;
                    }
                }
            }
            mcpServers = Object.values(serverMap).filter(
                lambda(s: Any) -> Any { return len(s.tools) > 0; }
            );

            # Build full message history
            messages = [];
            if llmConfig.systemPrompt {
                messages.push({"role": "system", "content": llmConfig.systemPrompt});
            }
            for msg in chatMessages {
                if msg.role != "system" {
                    cleanMsg = {"role": msg.role, "content": msg.content or ""};
                    if msg.tool_calls { cleanMsg.tool_calls = msg.tool_calls; }
                    if msg.tool_call_id { cleanMsg.tool_call_id = msg.tool_call_id; }
                    messages.push(cleanMsg);
                }
            }

            userMsg = {"role": "user", "content": userMessage};
            messages.push(userMsg);
            addChatMessage(userMsg);
            addAgentTraceEvent({"type": "user_message", "timestamp": Date.now(), "data": {"content": userMessage}});
            addAgentTraceEvent({
                "type": "llm_call_start",
                "timestamp": Date.now(),
                "data": {"model": llmConfig.model, "mode": "serverSide", "toolCount": len(allTools), "servers": len(mcpServers)}
            });

            try {
                result = await root spawn agent_run(
                    messages=messages,
                    mcp_servers=mcpServers,
                    model=llmConfig.model,
                    provider=llmConfig.provider or "openai",
                    api_key=llmConfig.apiKey,
                    temperature=llmConfig.temperature or 0.7,
                    max_tokens=llmConfig.maxTokens or 4096,
                    max_iterations=llmConfig.maxIterations or 10
                );

                resp = extractReport(result);

                if not resp {
                    addChatMessage({"role": "system", "content": "No response from agent_run walker."});
                    return;
                }

                # Replay server-side trace events into the frontend trace panel
                now = Date.now();
                for evt in (resp.trace or []) {
                    addAgentTraceEvent(Object.assign({}, evt, {"timestamp": now}));
                }

                if resp.usage {
                    addTokenUsage({
                        "prompt_tokens": resp.usage.prompt_tokens or 0,
                        "completion_tokens": resp.usage.completion_tokens or 0,
                        "total_tokens": resp.usage.total_tokens or 0
                    });
                }

                if resp.ok {
                    addChatMessage({"role": "assistant", "content": resp.final_content or ""});
                    addAgentTraceEvent({
                        "type": "final_response",
                        "timestamp": Date.now(),
                        "data": {
                            "content": resp.final_content,
                            "iterations": resp.iterations,
                            "mode": "serverSide"
                        }
                    });
                } else {
                    errMsg = friendlyError(resp.error or "Unknown error");
                    addChatMessage({"role": "system", "content": errMsg, "errorKind": classifyError(resp.error or "")});
                    addAgentTraceEvent({"type": "error", "timestamp": Date.now(), "data": {"error": resp.error}});
                }
            } except Exception as e {
                errMsg = friendlyError(String(e));
                addChatMessage({"role": "system", "content": errMsg, "errorKind": classifyError(String(e))});
                addAgentTraceEvent({"type": "error", "timestamp": Date.now(), "data": {"error": String(e)}});
            }
        }

        # ── Public entry point ───────────────────────────────────────────────
        async def runAgentLoop(connection: Any, userMessage: str) -> None {
            _abortFlag.aborted = False;
            setAgentRunning(True);

            try {
                if (llmConfig.agentMode or "perTurn") == "serverSide" {
                    await runServerSideLoop(connection, userMessage);
                } else {
                    await runPerTurnLoop(connection, userMessage);
                }
            } except Exception as e {
                addChatMessage({"role": "system", "content": "Unexpected error: " + String(e)});
            }

            setAgentRunning(False);
        }

        def abortAgent -> None {
            _abortFlag.aborted = True;
            # Also reject any pending confirmation
            if _confirmResolve.fn {
                _confirmResolve.fn(False);
                _confirmResolve.fn = None;
            }
        }

        def approveToolCall -> None {
            if _confirmResolve.fn { _confirmResolve.fn(True); }
        }

        def denyToolCall -> None {
            if _confirmResolve.fn { _confirmResolve.fn(False); }
        }

        return {
            "runAgentLoop": runAgentLoop,
            "abortAgent": abortAgent,
            "approveToolCall": approveToolCall,
            "denyToolCall": denyToolCall
        };
    }
}

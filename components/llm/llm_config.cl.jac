"""LlmConfigPanel – collapsible LLM configuration for agentic mode."""

cl import from "react" { useState, useEffect }
cl import from "lucide-react" {
    Settings, ChevronDown, ChevronRight, Eye, EyeOff,
    Cpu, ShieldCheck, Wrench, Server, ToggleLeft, ToggleRight
}
cl import from ...store.mcp_store { useMcpStore }

cl {
    glob MODEL_SUGGESTIONS: Any = {
        "openai": ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o1-mini", "o3-mini"],
        "anthropic": ["claude-sonnet-4-20250514", "claude-haiku-4-20250414", "claude-opus-4-20250514"],
        "google": [
            "gemini/gemini-2.5-pro-preview-05-06",
            "gemini/gemini-2.5-flash-preview-04-17",
            "gemini/gemini-2.0-flash",
            "gemini/gemini-2.0-flash-lite",
            "gemini/gemini-1.5-pro",
            "gemini/gemini-1.5-flash",
            "gemini/gemini-1.5-flash-8b"
        ],
        "groq": ["llama-3.1-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"],
        "together": ["meta-llama/Llama-3-70b-chat-hf", "mistralai/Mixtral-8x7B-Instruct-v0.1"]
    };

    # ── Tool Filter Section ──────────────────────────────────────────────────

    def ToolFilterSection(props: Any) -> JsxElement {
        allTools = props.allTools;
        enabledTools = props.enabledTools;
        onToggle = props.onToggle;
        onSelectAll = props.onSelectAll;
        onClearAll = props.onClearAll;

        has open: bool = False;

        totalCount = len(allTools);
        enabledCount = enabledTools == None and totalCount or len(enabledTools or []);

        return <div className="border border-border rounded-lg overflow-hidden">
            <button
                onClick={lambda -> None { open = not open; }}
                className="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-muted/30 transition-colors cursor-pointer"
            >
                <Wrench size={12} className="text-primary flex-shrink-0"/>
                <span className="text-xs font-medium text-foreground flex-1">Tool Access</span>
                <span className="text-xs text-muted-foreground">{enabledCount}/{totalCount} enabled</span>
                {open and <ChevronDown size={12} className="text-muted-foreground"/> or <ChevronRight size={12} className="text-muted-foreground"/>}
            </button>

            {open and <div className="border-t border-border">
                <div className="flex items-center gap-2 px-3 py-1.5 bg-muted/20">
                    <button
                        onClick={onSelectAll}
                        className="text-xs text-primary hover:underline cursor-pointer"
                    >All</button>
                    <span className="text-muted-foreground/40">·</span>
                    <button
                        onClick={onClearAll}
                        className="text-xs text-muted-foreground hover:text-foreground hover:underline cursor-pointer"
                    >None</button>
                </div>
                <div className="max-h-40 overflow-y-auto divide-y divide-border/50">
                    {allTools.map(lambda(tool: Any) -> Any {
                        isEnabled = enabledTools == None or enabledTools.includes(tool.name);
                        return <label
                            key={tool.name}
                            className="flex items-center gap-2 px-3 py-1.5 hover:bg-muted/20 cursor-pointer"
                        >
                            <input
                                type="checkbox"
                                checked={Boolean(isEnabled)}
                                onChange={lambda(e: Any) -> None { onToggle(tool.name, e.target.checked); }}
                                className="accent-primary cursor-pointer"
                            />
                            <div className="flex-1 min-w-0">
                                <p className="text-xs font-mono text-foreground truncate">{tool.name}</p>
                                {tool._serverName and <p className="text-xs text-muted-foreground/50 truncate">{tool._serverName}</p>}
                            </div>
                        </label>;
                    })}
                </div>
            </div>}
        </div>;
    }

    # ── Toggle Switch ────────────────────────────────────────────────────────

    def ToggleSwitch(props: Any) -> JsxElement {
        checked = props.checked;
        onChange = props.onChange;
        label = props.label;
        description = props.description;

        return <label className="flex items-center gap-2.5 cursor-pointer group">
            <div
                className={f"relative w-8 h-4 rounded-full transition-colors flex-shrink-0 {
                    'bg-primary' if checked else 'bg-muted-foreground/30'
                }"}
                onClick={lambda -> None { onChange(not checked); }}
            >
                <div className={f"absolute top-0.5 w-3 h-3 rounded-full bg-white shadow-sm transition-transform {
                    'translate-x-4' if checked else 'translate-x-0.5'
                }"}/>
            </div>
            <div className="min-w-0">
                <p className="text-xs font-medium text-foreground leading-none">{label}</p>
                {description and <p className="text-xs text-muted-foreground/60 mt-0.5">{description}</p>}
            </div>
        </label>;
    }

    # ── Main Panel ───────────────────────────────────────────────────────────

    def:pub LlmConfigPanel -> JsxElement {
        llmConfig = useMcpStore(lambda(s: Any) -> Any { return s.llmConfig; });
        updateLlmConfig = useMcpStore(lambda(s: Any) -> Any { return s.updateLlmConfig; });
        connections = useMcpStore(lambda(s: Any) -> Any { return s.connections; });

        has expanded: bool = False;
        has showKey: bool = False;

        provider = llmConfig.provider or "openai";
        model = llmConfig.model or "gpt-4o-mini";
        suggestions = MODEL_SUGGESTIONS[provider] or [];
        enabledTools = llmConfig.enabledTools;

        # Collect all tools from all connected servers
        allTools = [];
        for conn in connections {
            if conn.status == "connected" {
                caps = conn.capabilities or {};
                for tool in (caps.tools or []) {
                    if tool.name {
                        allTools.push(Object.assign({}, tool, {"_serverName": conn.name}));
                    }
                }
            }
        }

        # Load API key from sessionStorage on mount if sessionKey opt-in
        useEffect(lambda -> Any {
            if llmConfig.sessionKey {
                saved = sessionStorage.getItem("mcp_llm_api_key");
                if saved and not llmConfig.apiKey {
                    updateLlmConfig({"apiKey": saved});
                }
            }
            return lambda -> None {};
        }, []);

        def handleKeyChange(val: str) -> None {
            updateLlmConfig({"apiKey": val});
            if llmConfig.sessionKey {
                if val { sessionStorage.setItem("mcp_llm_api_key", val); }
                else { sessionStorage.removeItem("mcp_llm_api_key"); }
            }
        }

        def handleSessionKeyToggle(val: bool) -> None {
            updateLlmConfig({"sessionKey": val});
            if val and llmConfig.apiKey {
                sessionStorage.setItem("mcp_llm_api_key", llmConfig.apiKey);
            } else {
                sessionStorage.removeItem("mcp_llm_api_key");
            }
        }

        def toggleTool(toolName: str, checked: bool) -> None {
            current = enabledTools;
            allNames = allTools.map(lambda(t: Any) -> Any { return t.name; });
            if current == None {
                # Start from all-enabled, remove this one
                if not checked {
                    updateLlmConfig({"enabledTools": allNames.filter(lambda(n: Any) -> Any { return n != toolName; })});
                }
            } else {
                if checked {
                    updated = current.concat([toolName]);
                    # If all enabled again → reset to null (all)
                    if updated.length == allNames.length { updateLlmConfig({"enabledTools": None}); }
                    else { updateLlmConfig({"enabledTools": updated}); }
                } else {
                    updateLlmConfig({"enabledTools": current.filter(lambda(n: Any) -> Any { return n != toolName; })});
                }
            }
        }

        # Status summary for collapsed header
        modeLabel = "Server-side" if (llmConfig.agentMode or "perTurn") == "serverSide" else "Per-turn";
        confirmLabel = " · Confirm" if llmConfig.confirmMode else "";
        toolLabel = f" · {len(enabledTools or [])}/{len(allTools)} tools" if enabledTools != None else "";

        return <div className="flex-shrink-0 border-b border-border bg-card/40">
            <button
                onClick={lambda -> None { expanded = not expanded; }}
                className="w-full flex items-center gap-2.5 px-4 py-2.5 hover:bg-muted/40 transition-colors cursor-pointer"
            >
                <div className="w-6 h-6 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0">
                    <Settings size={13} className="text-primary"/>
                </div>
                <div className="flex-1 flex items-center gap-2 min-w-0 text-left">
                    <span className="text-xs font-semibold text-foreground">LLM Config</span>
                    <span className="text-xs text-muted-foreground truncate">
                        {provider} / {model}{toolLabel}{confirmLabel}
                    </span>
                    <span className="text-xs text-muted-foreground/50">{modeLabel}</span>
                    {llmConfig.apiKey and <span className="w-1.5 h-1.5 rounded-full bg-success flex-shrink-0"/>}
                    {not llmConfig.apiKey and <span className="text-xs text-warning">No API key</span>}
                </div>
                {expanded and <ChevronDown size={14} className="text-muted-foreground flex-shrink-0"/> or <ChevronRight size={14} className="text-muted-foreground flex-shrink-0"/>}
            </button>

            {expanded and <div className="px-4 pb-4 space-y-3">

                <div className="grid grid-cols-2 gap-3">
                    <div>
                        <label className="block text-xs font-medium text-muted-foreground mb-1.5">Provider</label>
                        <select
                            value={provider}
                            onChange={lambda(e: Any) -> None {
                                newProvider = e.target.value;
                                newSuggestions = MODEL_SUGGESTIONS[newProvider] or [];
                                defaultModel = newSuggestions[0] if len(newSuggestions) > 0 else "";
                                updateLlmConfig({"provider": newProvider, "model": defaultModel});
                            }}
                            className="w-full bg-background border border-input rounded-lg px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring/50 cursor-pointer"
                        >
                            <option value="openai">OpenAI</option>
                            <option value="anthropic">Anthropic</option>
                            <option value="google">Google Gemini</option>
                            <option value="groq">Groq</option>
                            <option value="together">Together AI</option>
                        </select>
                    </div>
                    <div>
                        <label className="block text-xs font-medium text-muted-foreground mb-1.5">Model</label>
                        <input
                            type="text"
                            list="model-suggestions-list"
                            value={model}
                            onChange={lambda(e: Any) -> None { updateLlmConfig({"model": e.target.value}); }}
                            placeholder="Model name..."
                            className="w-full bg-background border border-input rounded-lg px-3 py-2 text-sm text-foreground placeholder-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring/50"
                        />
                        <datalist id="model-suggestions-list">
                            {suggestions.map(lambda(m: Any) -> Any {
                                return <option key={m} value={m}/>;
                            })}
                        </datalist>
                    </div>
                </div>

                <div>
                    <label className="block text-xs font-medium text-muted-foreground mb-1.5">API Key</label>
                    <div className="relative">
                        <input
                            type={showKey and "text" or "password"}
                            value={llmConfig.apiKey or ""}
                            onChange={lambda(e: Any) -> None { handleKeyChange(e.target.value); }}
                            placeholder="sk-..."
                            className="w-full bg-background border border-input rounded-lg px-3 py-2 pr-10 text-sm text-foreground font-mono placeholder-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring/50"
                        />
                        <button
                            onClick={lambda -> None { showKey = not showKey; }}
                            className="absolute right-2.5 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground cursor-pointer"
                        >
                            {showKey and <EyeOff size={14}/> or <Eye size={14}/>}
                        </button>
                    </div>
                    <div className="flex items-center justify-between mt-1.5">
                        <p className="text-xs text-muted-foreground/60">Never sent to our servers.</p>
                        <label className="flex items-center gap-1.5 cursor-pointer">
                            <input
                                type="checkbox"
                                checked={Boolean(llmConfig.sessionKey)}
                                onChange={lambda(e: Any) -> None { handleSessionKeyToggle(e.target.checked); }}
                                className="accent-primary cursor-pointer"
                            />
                            <span className="text-xs text-muted-foreground">Keep for session</span>
                        </label>
                    </div>
                </div>

                <div>
                    <label className="block text-xs font-medium text-muted-foreground mb-1.5">System Prompt</label>
                    <textarea
                        value={llmConfig.systemPrompt or ""}
                        onChange={lambda(e: Any) -> None { updateLlmConfig({"systemPrompt": e.target.value}); }}
                        rows={3}
                        className="w-full bg-background border border-input rounded-lg px-3 py-2 text-sm text-foreground placeholder-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring/50 resize-none"
                        placeholder="You are a helpful assistant..."
                    />
                </div>

                <div className="grid grid-cols-3 gap-3">
                    <div>
                        <label className="block text-xs font-medium text-muted-foreground mb-1.5">Temperature</label>
                        <input
                            type="number" min="0" max="2" step="0.1"
                            value={llmConfig.temperature or 0.7}
                            onChange={lambda(e: Any) -> None { updateLlmConfig({"temperature": parseFloat(e.target.value) or 0.7}); }}
                            className="w-full bg-background border border-input rounded-lg px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring/50"
                        />
                    </div>
                    <div>
                        <label className="block text-xs font-medium text-muted-foreground mb-1.5">Max Tokens</label>
                        <input
                            type="number" min="100" max="128000" step="100"
                            value={llmConfig.maxTokens or 4096}
                            onChange={lambda(e: Any) -> None { updateLlmConfig({"maxTokens": parseInt(e.target.value) or 4096}); }}
                            className="w-full bg-background border border-input rounded-lg px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring/50"
                        />
                    </div>
                    <div>
                        <label className="block text-xs font-medium text-muted-foreground mb-1.5">Max Iters</label>
                        <input
                            type="number" min="1" max="50" step="1"
                            value={llmConfig.maxIterations or 10}
                            onChange={lambda(e: Any) -> None { updateLlmConfig({"maxIterations": parseInt(e.target.value) or 10}); }}
                            className="w-full bg-background border border-input rounded-lg px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring/50"
                        />
                    </div>
                </div>

                <div className="pt-1 border-t border-border space-y-2.5">
                    <div className="flex items-center gap-4">
                        <div className="flex-1">
                            <label className="block text-xs font-medium text-muted-foreground mb-1.5 flex items-center gap-1">
                                <Cpu size={11}/>
                                Agent Mode
                            </label>
                            <div className="flex rounded-lg border border-input overflow-hidden text-xs">
                                <button
                                    onClick={lambda -> None { updateLlmConfig({"agentMode": "perTurn"}); }}
                                    className={f"flex-1 px-2 py-1.5 font-medium transition-colors cursor-pointer {
                                        'bg-primary text-primary-foreground' if (llmConfig.agentMode or 'perTurn') == 'perTurn' else 'text-muted-foreground hover:text-foreground'
                                    }"}
                                >Observable</button>
                                <button
                                    onClick={lambda -> None { updateLlmConfig({"agentMode": "serverSide", "confirmMode": False}); }}
                                    className={f"flex-1 px-2 py-1.5 font-medium transition-colors cursor-pointer {
                                        'bg-primary text-primary-foreground' if (llmConfig.agentMode or 'perTurn') == 'serverSide' else 'text-muted-foreground hover:text-foreground'
                                    }"}
                                >Server-side</button>
                            </div>
                            <p className="text-xs text-muted-foreground/50 mt-1">
                                {(llmConfig.agentMode or "perTurn") == "serverSide" and "Full loop runs on backend · tool confirmation unavailable" or "Per-turn calls with live trace"}
                            </p>
                        </div>
                    </div>

                    <ToggleSwitch
                        checked={Boolean(llmConfig.confirmMode)}
                        onChange={lambda(v: Any) -> None {
                            if v { updateLlmConfig({"confirmMode": True, "agentMode": "perTurn"}); }
                            else { updateLlmConfig({"confirmMode": False}); }
                        }}
                        label="Tool Confirmation"
                        description={(llmConfig.agentMode or "perTurn") == "serverSide" and "Not available in server-side mode" or "Approve each tool call before execution"}
                    />
                </div>

                {len(allTools) > 0 and <ToolFilterSection
                    allTools={allTools}
                    enabledTools={enabledTools}
                    onToggle={toggleTool}
                    onSelectAll={lambda -> None { updateLlmConfig({"enabledTools": None}); }}
                    onClearAll={lambda -> None { updateLlmConfig({"enabledTools": []}); }}
                />}

            </div>}
        </div>;
    }
}

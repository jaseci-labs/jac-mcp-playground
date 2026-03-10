"""MCP Store – React Context, no external state library."""

cl import from "react" { createContext, useContext }

cl {
    glob McpCtx: Any = createContext(None);

    def:pub McpProvider(props: Any) -> JsxElement {
        has connections: Any = [];
        has activeConnectionId: Any = None;
        has history: Any = [];
        has activeTab: Any = "tools";
        has selectedTool: Any = None;
        has selectedPrompt: Any = None;
        has selectedResource: Any = None;
        has logsPanelOpen: bool = True;
        has sidebarOpen: bool = True;
        has addModalOpen: bool = False;

        # ── LLM Agentic Mode State ──
        has chatMessages: Any = [];
        has agentRunning: bool = False;
        has agentTrace: Any = [];
        has pendingConfirmation: Any = None;
        has llmConfig: Any = {
            "provider": "openai",
            "model": "gpt-4o-mini",
            "apiKey": "",
            "temperature": 0.7,
            "maxTokens": 4096,
            "systemPrompt": "You are a helpful assistant that can use tools to help answer questions. When using tools, always explain what you're doing and why.",
            "maxIterations": 10,
            "agentMode": "perTurn",
            "confirmMode": False,
            "enabledTools": None,
            "sessionKey": False
        };
        has totalTokenUsage: Any = {"prompt": 0, "completion": 0, "total": 0};

        def addConnection(conn: Any) -> None {
            connections = lambda(prev: Any) -> Any { return prev.concat([conn]); };
        }
        def removeConnection(id: Any) -> None {
            connections = lambda(prev: Any) -> Any { return prev.filter(lambda(c: Any) -> Any { return c.id != id; }); };
            activeConnectionId = lambda(prev: Any) -> Any {
                if prev == id { return None; }
                return prev;
            };
        }
        def updateConnection(id: Any, patch: Any) -> None {
            connections = lambda(prev: Any) -> Any {
                return prev.map(lambda(c: Any) -> Any {
                    if c.id == id { return Object.assign({}, c, patch); }
                    return c;
                });
            };
        }
        def addHistoryEntry(`entry: Any) -> None {
            history = lambda(prev: Any) -> Any { return [`entry].concat(prev).slice(0, 200); };
        }
        def updateHistoryEntry(id: Any, patch: Any) -> None {
            history = lambda(prev: Any) -> Any {
                return prev.map(lambda(e: Any) -> Any {
                    if e.id == id { return Object.assign({}, e, patch); }
                    return e;
                });
            };
        }
        def clearHistory -> None { history = []; }
        def toggleLogsPanel -> None { logsPanelOpen = lambda(prev: Any) -> Any { return not prev; }; }
        def toggleSidebar -> None { sidebarOpen = lambda(prev: Any) -> Any { return not prev; }; }
        def openAddModal -> None { addModalOpen = True; }
        def closeAddModal -> None { addModalOpen = False; }

        # ── LLM Agentic Mode Mutations ──
        def addChatMessage(msg: Any) -> None {
            chatMessages = lambda(prev: Any) -> Any { return prev.concat([msg]); };
        }
        def replaceChatMessages(msgs: Any) -> None {
            chatMessages = msgs;
        }
        def clearChat -> None {
            chatMessages = [];
            agentTrace = [];
            totalTokenUsage = {"prompt": 0, "completion": 0, "total": 0};
        }
        def updateAgentRunning(val: Any) -> None {
            agentRunning = val;
        }
        def addAgentTraceEvent(evt: Any) -> None {
            agentTrace = lambda(prev: Any) -> Any { return prev.concat([evt]); };
        }
        def clearAgentTrace -> None {
            agentTrace = [];
        }
        def updateLlmConfig(patch: Any) -> None {
            llmConfig = lambda(prev: Any) -> Any { return Object.assign({}, prev, patch); };
        }
        def addTokenUsage(usage: Any) -> None {
            totalTokenUsage = lambda(prev: Any) -> Any {
                return {
                    "prompt": prev.prompt + (usage.prompt_tokens or 0),
                    "completion": prev.completion + (usage.completion_tokens or 0),
                    "total": prev.total + (usage.total_tokens or 0)
                };
            };
        }
        def updatePendingConfirmation(conf: Any) -> None {
            pendingConfirmation = conf;
        }

        store = {
            "connections": connections,
            "activeConnectionId": activeConnectionId,
            "addConnection": addConnection,
            "removeConnection": removeConnection,
            "updateConnection": updateConnection,
            "setActiveConnection": lambda(id: Any) -> None { activeConnectionId = id; },
            "history": history,
            "addHistoryEntry": addHistoryEntry,
            "updateHistoryEntry": updateHistoryEntry,
            "clearHistory": clearHistory,
            "activeTab": activeTab,
            "setActiveTab": lambda(tab: Any) -> None { activeTab = tab; },
            "selectedTool": selectedTool,
            "setSelectedTool": lambda(t: Any) -> None { selectedTool = t; },
            "selectedPrompt": selectedPrompt,
            "setSelectedPrompt": lambda(p: Any) -> None { selectedPrompt = p; },
            "selectedResource": selectedResource,
            "setSelectedResource": lambda(r: Any) -> None { selectedResource = r; },
            "logsPanelOpen": logsPanelOpen,
            "toggleLogsPanel": toggleLogsPanel,
            "sidebarOpen": sidebarOpen,
            "toggleSidebar": toggleSidebar,
            "addModalOpen": addModalOpen,
            "openAddModal": openAddModal,
            "closeAddModal": closeAddModal,
            "chatMessages": chatMessages,
            "agentRunning": agentRunning,
            "agentTrace": agentTrace,
            "pendingConfirmation": pendingConfirmation,
            "llmConfig": llmConfig,
            "totalTokenUsage": totalTokenUsage,
            "addChatMessage": addChatMessage,
            "replaceChatMessages": replaceChatMessages,
            "clearChat": clearChat,
            "setAgentRunning": updateAgentRunning,
            "addAgentTraceEvent": addAgentTraceEvent,
            "clearAgentTrace": clearAgentTrace,
            "updateLlmConfig": updateLlmConfig,
            "addTokenUsage": addTokenUsage,
            "setPendingConfirmation": updatePendingConfirmation
        };

        return <McpCtx.Provider value={store}>{props.children}</McpCtx.Provider>;
    }

    def:pub useMcpStore(selector: Any = None) -> Any {
        ctx = useContext(McpCtx);
        if selector { return selector(ctx); }
        return ctx;
    }
}

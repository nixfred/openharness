"""What the model sees for the harness_attention tool."""

HARNESS_ATTENTION = {
    "name": "harness_attention",
    "description": (
        "Ask the local OpenHarness daemon which agents need a person right now. Returns the fleet "
        "summary (most urgent state and count), every agent with its state (working, waiting, "
        "permission, failed, done, idle, offline) and detail, and any collision alerts (two agents "
        "on the same file, folder or branch in the last hour). Use it when asked 'who needs me', "
        "'what is waiting', 'which agent failed', or before deciding what to work on next."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "only_urgent": {
                "type": "boolean",
                "description": "Return only agents that need a person (waiting, permission, failed) and alerts.",
            },
        },
        "required": [],
    },
}

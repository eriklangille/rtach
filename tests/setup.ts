// Tests run as if outside any rtach session, even when started from one: a test's rtach
// would otherwise act on that session (`ws` defaults PANE to it, `clauntty` writes to its
// pipe).
for (const name of ["RTACH_SESSION_ID", "RTACH_SOCKET", "RTACH_CMD_PIPE"]) delete process.env[name];

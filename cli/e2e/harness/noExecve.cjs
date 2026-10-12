// A Node without `process.execve`, as before Node 22.15: a master that finds another bundle on disk cannot
// re-execute on it, keeps its own code and starts the core on the bundle on disk (src/harnessd/reexec.ts). That is
// how a core of one build comes to run under a master of another, which e2e/messagesSkew.e2e.ts needs.
delete process.execve

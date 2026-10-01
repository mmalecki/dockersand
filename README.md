# dockersand
`dockersand` wraps Docker and gVisor, creating lightweight sandboxes
for your trusted-ish workloads, such as well-meaning LLM agents.
It prevents them from accessing out-of-scope files, devices and
(optionally) network resources.

# Gemini 3.1 Pro Deep Search

**Topic:** agent_retrieval
**Question:** MCP postgres pgvector tool surface area for LLM agents 2026 best practice retrieve_chunks describe_schema observability
**Model:** gemini-3.1-pro-preview
**Generated:** 2026-05-19 23:49
**Sources cited:** 4

---

In 2026, integrating Large Language Model (LLM) agents with PostgreSQL and the `pgvector` extension relies heavily on Anthropic's Model Context Protocol (MCP), an open standard released in late 2024. A critical best practice is strictly minimizing the "tool surface area" exposed to agents, as excessive tool definitions rapidly exhaust model context windows. For example, analysis by EclipseSource and reports from the r/ClaudeCode community on March 19, 2026, showed that stacking MCPs like Postgres, Playwright, and Azure can consume 83.3K tokens -- or 41.6% of a 200,000-token context window -- before a single prompt is issued. To mitigate this, developers avoid exposing hundreds of distinct API endpoints. The `postgres-mcp` repository by GitHub user "neverinfamous," updated May 19, 2026, advocates for "Code Mode" (`--tool-filter codemode`), a V8 isolate sandbox that replaces 278 specialized tools to achieve up to 90% token savings. Similarly, the Harness MCP v2 reduced its surface from approximately 175 tools to just 11

---

## Sources

[src-1] [comet.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEhsaM-WdfA6fEeTqjydHgeVG5bnVwrtDJVlEgSi0ck7QYbf5JMPwlMGYtkGze0JlzA7Z39jCZ3e5f3UCFjHuKkM8URuaiWNOyoK4pi60ix-jrub03Aaf4ZN3Lm7F1fbZ0MZmIdcib8tlOh_lExbqhcwhY=)
[src-2] [mindstudio.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFfDfK45atkFIidxiXExxIHNqp6xp0AS9PquVmUPIHIEXgahozvkFmR7JY5983Qm9dPs83UCruO5XLyEIoZRYFlMu4C1uml40j6MC-u3zDoDXMmtSJo5W8Gosnt6-vOn-ckRppEMGUOha4kJFiFoiyAiAOWR0rUSjlfhGFE5Vh_cbO5uDVG15YsPy7EBg==)
[src-3] [harness.io](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEeKZgsDdz6xNCobVOoWyj4EPGMBi0HGN0gbYLh1jV9UdTFBPNCTtjJkOkZCkwE8kMK7dbcEwCtX9wfto6QKh8w6_4nJwkNpoZsGkIh2RmXZOhAoxQ8GvFk5GQpNE_gwNhtXAcyXaNzR6gplYSB7tF_25s=)
[src-4] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGreAGv22JWLtDLjSMzTRAAo6lcNe0-DDmn8xAd3cmmbOe64F5Nsd3XMDKBwvW_HxcceLTbbsmMsbzsTySkZkP_IUhVwh7oGJOkryYN61y9kgzOQI6_vcwcO8TIVEtVpzkerbopKSR48A==)

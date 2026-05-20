# Gemini 3.1 Pro Deep Search

**Topic:** agent_retrieval
**Question:** official Anthropic model context protocol postgres server reference Supabase MCP Neon MCP read-only schema introspection tool surface area design 2026
**Model:** gemini-3.1-pro-preview
**Generated:** 2026-05-19 23:47
**Sources cited:** 10

---

## Synthesis

By early 2026, Anthropic's Model Context Protocol had matured into a dominant standard for bridging large language models with external PostgreSQL database environments. Originally published in 2024 and later donated to the Agentic AI Foundation, the protocol utilizes three core localized primitives--tools, resources, and prompts--to securely negotiate database capabilities over standard input/output streams or HTTP Server-Sent Events. The official Anthropic reference architecture approaches database integrations through a bifurcated design. It exposes schema introspection exclusively as read-only resources while reserving tools strictly for query execution. 

However, as agent ecosystems like Cursor and Claude Desktop scaled, third-party implementations and managed database providers began diverging from this reference design to optimize tool surface areas. Open-source iterations, such as Postgres MCP Pro, shifted their entire surface area strictly to tools--eschewing resources entirely--to maximize client compatibility and enable advanced features like execution plan analysis. Concurrently, enterprise platforms like Supabase and Neon adapted their MCP servers to mitigate autonomous agent risks. They achieved this by enforcing strict read-only modes, routing operations through abstraction layers to enforce Row-Level Security, and applying project scoping to prevent massive schema table dumps from overwhelming AI context windows. While technical guardrails are well-documented, specific data regarding the financial impact of agent-driven query volumes on API billing tiers remains unconfirmed.

## Key Facts

* Anthropic originally published the Model Context Protocol in November 2024 and donated it to the Linux Foundation's Agentic AI Foundation in December 2025 [src-1, src-3].
* The protocol surpassed 97 million installations by March 2026, with the `2025-11-25` specification serving as the dominant standard across agent environments [src-4, src-9].
* The official Anthropic `@modelcontextprotocol/server-postgres` reference utilizes a bifurcated design, handling schema introspection via read-only resources and dedicating tools strictly to executing read-only SQL queries [src-3].
* The 2026 third-party implementation Postgres MCP Pro dropped resources completely, moving its entire surface area to active tools to support broad client compatibility, database health checks, and query plan analysis via extensions like `pg_stat_statements` and `hypopg` [src-4, src-9].
* Supabase split its official MCP surface area into two packages: `@supabase/mcp-server-supabase` for administrative tasks and `@supabase/mcp-server-postgrest` for direct data operations routed through an API layer to enforce Row-Level Security [src-6].
* To prevent agents from corrupting schemas, Supabase implemented a strict read-only mode triggered by a `?read_only=true` parameter [src-6].
* Engaging the Supabase read-only mode forces all SQL operations to execute as a read-only user and disables mutating tools like `apply_migration`, `create_project`, `deploy_edge_function`, and `reset_branch` [src-6].
* Neon released a serverless Postgres MCP orchestration bridge updated in March 2026 (`npx @neondatabase/mcp-server-neon`) that translates natural language into API calls for provisioning branches and projects on scale-to-zero infrastructure [src-10].
* Both Neon and Supabase navigate AI context window constraints during schema introspection by utilizing project scoping, which selectively exposes relevant database tables instead of dumping thousands of columns into agent memory simultaneously [src-6, src-10].
* Current documentation indicates AI-generated queries count against standard API limits, though explicit dollar amounts for compute billing thresholds or specific tier pricing impacts driven by MCP volume remain unconfirmed [src-6, src-10].

## Open Questions

* What are the specific financial impacts or compute billing thresholds incurred by high-volume, autonomous MCP query execution on autoscaling database architectures?
* Are there any documented legal cases or liability precedents involving data anomalies or outages caused by autonomous agents operating via Supabase or Neon MCP servers?
* How do diverse AI client ecosystems benchmark the performance and reliability differences between Anthropic's bifurcated resource-tool design and a pure tool-based surface area?

---

## Sources

[src-1] [medium.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQECpws_ta2rOn8j4Umh_mae75FOsrvPXSXPg1uXYNSnu998mW9G4zVefD_F5PHo7JUwq89c558DsylRGnSxHMNOQpDptHlZOpQBZ47kEEnR74AWqcRxOt3nRMdbm_ePIHF4MJgwM7N-8juaQD9LF5lftm7eCakSlr1WLF6b2-Q0MzKqUutsAHnTIYJmCa9Tr1-dHfDnmV4f7Q==)
[src-2] [hidekazu-konishi.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQExJgGs2Kt6XJBICJyM26lRRjAhHBJDdkKVMwf4Fpnml8y_5OvYwXkKjGO3UtbKsUIFBzExRJZegxWvGLlQbIrdb7OEK22p6fQn25MEEay4bfn4wvzppRMIivMH5AcA0hbit1LvBZZ1_9wi5YBQRSBwCSeLvXkUGCN_AglBlwoeP7rHa_0ETw==)
[src-3] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGVfDaKPz3m1twyZtfHxC7x_IbZqoxsht84TOXT1Xg4lo-B5Lyl7YcFzFJVKmTXkF5cBVTR--l2dQTMtzzbMDYvQKh_adrnNzZTolssYBcSpRvDGaJY6KlkwF1P0SFi67TN3GluKA==)
[src-4] [mcpservers.org](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEdtBGAf7m1vxtlB_vkMFq8vF_deg-XufHFZYUON1u1z8v0_9e2Fq2s9JEJtI8P-J1D2Z5lQiIqtZfTZsP69eEMK40_q2SEQGJEWXjSX2FHoNy1m1YozXMh1mc8FweDzgz1DjFoj6ixhDzP4HGjWoe1FQ==)
[src-5] [skywork.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEpoj_3vkR3vAcL3LyPWYONGfCfhx-faOMQjS-K88ccXzAcCD_eZRWJRvb6T2rx6Bq5ng9GdTAOYJUjJCn8SdoOAMSQCXQhBFlMR9alcODxjxuPKMi7AKcPE3lRr6kLpZTTqM8dp81qf8kPTaciykNHMFwUmQx8hkPgbkItF6UuHMuDxq9m0aGL5RI=)
[src-6] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGtjjeXXX2j2yLEeiP9UF7vQ36gBobY20sTOMTVnPpxEb02PW0Eo58FAGBGnbzsUCTz69lg8U00WJWREdpLbb04ATvJdkQU_EiMG4of0UggN3Cy9U6ZJ0Rq0b56fdqtqxk_pG_hKPo4vUXgwlBT)
[src-7] [rconnect.tech](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFWmOFr--dQYW2wU2Hl-hcyByoXTaBNX7trohvjfCcyxs88TyvcUHAmCFwAPFtetUASnzjWiV5t422HG41Axbnvs6vuUZEWO_D-XMsS75IwzIJyz_x1OwcYSt5k0qCpA7aAUyJmrJeVvmKo-2GwP6n7hZC2WzY=)
[src-8] [skillhub.pm](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGkH_1GVYGnlpVqkNv5XOHE8fgVyB5-NM-jQ2aUruO5Lr5PQKw8LPfqET3k4CwK36xke1T9coHQx_L4as3yjrR0tTqM1JIi5EU5IAWk7_z7GfW2vJTC2mxSxfFQn39zIlS2yShWGh_nwlY=)
[src-9] [mcpservers.org](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFGraezfJFThHavyRUOYjIkchi6K-FhXYAQ2Aek6h88ANdmVHKLmH_xvj3FogM7Wxea_eZqoDz08glcD-jm-Oris0pSHx8YQRg48uhuMrlhztAY9f_zZcooL4UHxk-FnPfGgtcXiyEUw04VGHx4O7VY_6liFBCDtcJu)
[src-10] [mcp.directory](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEbf7qqMVFjZmXlVlHZImQ9sJMUW4BYUdQv6NOeiiTGS35lcnscWQyxs8MkM3TcwYa2pRzBivFpHGB6_BcRp7wNrVG45LvV7nLafVlTwaXLqWlXmAapeQJxHDgf6S9DN2aIJinw-yd7NB8RafQHKv7cyIWg-7__H5cdxcFD)

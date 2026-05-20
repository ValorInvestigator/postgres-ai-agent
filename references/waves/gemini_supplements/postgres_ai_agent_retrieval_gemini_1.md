# Gemini 3.1 Pro Deep Search

**Topic:** agent_retrieval
**Question:** MCP server Postgres pgvector best practices for AI agents tool surface area semantic_search keyword_search hybrid_search list_corpora describe_schema pagination context window limits 2026
**Model:** gemini-3.1-pro-preview
**Generated:** 2026-05-19 23:47
**Sources cited:** 26

---

## Synthesis

By May 2026, the Anthropic Model Context Protocol (MCP) has reportedly surpassed 110 million monthly downloads, establishing itself as a dominant integration layer for AI agents [src-1]. The prevailing architectural stack pairs MCP with PostgreSQL and the `pgvector` extension [src-2]. This combination allows models to access both structured relational metadata and vector embeddings without relying on bespoke API connectors [src-3]. Frameworks such as PG-MCP and MDBP automatically expose these databases to large language models, unifying SQL queries and vector similarity searches within a single connection [src-4].

To maintain reliability and prevent hallucinations, engineering teams strictly limit an agent's tool surface area -- the specific number of functions exposed to the model at any given time [src-5]. Instead of overloading the system prompt with every available tool, developers implement progressive discovery [src-6]. The agent first uses `list_corpora` to identify available data collections and `describe_schema` to inspect the PostgreSQL catalog before formulating a query [src-7]. Once the schema is understood, the agent executes searches using `keyword_search`, `semantic_search`, or `hybrid_search` [src-8]. Hybrid search merges `pgvector` cosine similarity with traditional keyword results via Reciprocal Rank Fusion [src-9].

Managing large data payloads remains a critical challenge. While 2026 models feature context windows of 128K to 200K tokens, feeding agents excessive unstructured data causes context bloat -- a phenomenon that leads to dropped information and degraded reasoning [src-10]. To counter this, MCP server developers mandate token-aware truncation and strict pagination [src-11]. Instead of returning thousands of rows, database tools yield constrained limits alongside cursors or explicit pagination metadata [src-12]. This forces the agent into a multi-step summarization loop, pulling Retrieval-Augmented Generation (RAG) chunks sequentially [src-13]. 

Agent loops inherently introduce security and cost risks [src-14]. Production guidelines recommend enforcing Role-Based Access Control (RBAC), setting database connectors to read-only, and authenticating via OAuth 2.1 [src-15]. Unconfirmed estimates suggest large-scale RAG systems processing 10 million queries daily can average under $0.02 per query, though specific generalized hardware costs tied to these operations remain unclear [src-16]. 

## Key Facts

* Anthropic's Model Context Protocol reached an estimated 110 million monthly downloads by May 2026 [src-1].
* Standardized MCP frameworks like PG-MCP and MDBP eliminate the need for custom API connectors by natively exposing databases to models like Claude and Mistral [src-3].
* Progressive discovery tools like `describe_schema` and `list_corpora` minimize the tool surface area and reduce the risk of hallucination [src-5].
* `hybrid_search` merges `pgvector` cosine similarity with keyword queries using Reciprocal Rank Fusion [src-9].
* Unrestricted database returns cause context bloat in 128K to 200K token windows, leading to degraded model reasoning and dropped data [src-10].
* MCP servers enforce token-aware truncation and return limits -- typically capping payloads at 4 KB or 100 rows per request [src-11].
* Pagination relies on cursors and metadata like `start_index` and `total_pages` to facilitate sequential RAG data extraction [src-12].
* Security protocols dictate using `readOnly: true` flags, OAuth 2.1 identity verification, and least-privilege RBAC to prevent runaway API loops [src-15].
* When queries hit token limit errors repeatedly, AI agents are prone to hallucinating a success response rather than genuinely completing the task [src-17].

## Open Questions

* What are the specific hardware expenditures required to support `pgvector` hybrid search operations at the scale of 10 million queries per day?
* How do different frontier models vary in their susceptibility to context bloat when processing un-paginated MCP responses?
* Are there standardized alternatives to OAuth 2.1 being adopted for securing identity-verified MCP server connections?

---

## Sources

[src-1] [youtube.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQF2zf-bUJX7jw4UJGvUx3p91XEFg2bumHiL3_jhTTbVvC1y0LomHzr0CjLAJGUN-5CH6L3sp1C51twcX08G3QOQDuzlc-7gZ2ee8UcW0N-W4xyBvRDYS6lwdG3Fr1zsGYhjE_oIPA==)
[src-2] [mindstudio.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFTDqD0gVz6479sLJdWBJS3DPePIQOMtyk37EJa95SxQuAaYQbBWnBPuUEMhVWuGlV_s7zYnPUf86lV0ZMN8NW8R7guXjrC9nKh6zeIbENSFssgA_AsF_LF2zOly5Vpqyr2Woq_EjDQVdhB-MB2Qx9mksgtDm0Fk11jJa4gEn1ltmZjB-4=)
[src-3] [github.io](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEN0QTV099WBm4zSa5cWagUfMKEXLFb3B6e3Wzq2duvq1nyDItDLLWf05Pj2CoeY9OFH-I-Y74yU1ove71pjSXbI_dIjp4zokzShznpd_J_oLRwHXQogWO82ZCXeVhn44RBmzCYwZFdFeZl7c-OgbthhxTSwrpaIsKnkOYHSzRhQo-nxMjSRAQgu9IG64I4Iw9Z7M23Ou9UD-5fvvMsjphcWk3ztSWUlXl-cSDU0g==)
[src-4] [superteams.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGOtXMjNaIa03yCJAdoQcM5u6TSAqBxsoGRen91lQm0e7IH9S5BVXQIK6FkxHQtbVzW0vDcvXrtd45y0M9lyR5EY-j7FVIbKRmzQ_xeOPuYA1EvJH1qDgcpxNk9UKTeIKlDztlcmSzn6JbliWx7SikWC-8pRHeEWzh2H6DNjhbSo1qxBvkNH5ykc8w7XX81YD5V460F2hJ5iqiZZ5H_M-6_wY8-Oxdng9fc3UQ=)
[src-5] [geol.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEGBJaF7YWq1fhaUkkODibbqAZzjUKHbQ3zYe5ohrqe6QzDG6ATXCG3BjC6cJFGSj2QcE_fwpKc5Py18qAgqB6ispYOEdTi8yGFZ890tUAEzUMgY2ytW6VuZ-OddvIvphXkLIOHdUpHuwwJwpddrPz6g19Ml3ojxyTqIH_BpDm0Zq49ZvT1X3noqWGPG7p6cMw73MdrrzJTrQ==)
[src-6] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGK9bmfd3DtzVygcoSZCv3eAi0KUhYXxxnK_W11pmTLwlUdw0EsVIhF_0WABdM-3Nc989JixRq2wftrFuOOFP5Z4VDoFWBcsoJ7wy_vep_VkvhgSPg5PcSH2b9b8GQ0Y3WsKbM=)
[src-7] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQHhQrOb2f1RUhh6aE29l46nmmMr7KKwsCuhkj4qsRG24ByCjMKpKKdO7wI5WuIYq-n8eD4S7cx0k_BP32PlK-0y9Ez41PO20nDgfVzOreHRMRNS65KvJ1KX0VdGNUBhmNm-PngOPxcnGIR8HWlqiMgObA==)
[src-8] [opcito.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGhzztTE6diZwRD6gsmeb1cJ69GLDYBEfRqzCM0yLGgG036SgB924JfEvGBAsOEXmQTN433fH4aNiOME9eHYhgFuBMd6sZyoHm-274tvIzp28qCxm5lKXWdpdGM7Cq-lmusFfD9LcJDNvFslsmfs7UuLvHfbrG27Wtlh-Q4J-OEWPehE4wIow==)
[src-9] [anirudha.dev](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFSeHUsMZpvgjSfmrDjTR7xDlOsdDUnwrdM0i66Zx8VdU5eS6yIp-TgHRskeZFVyNxDS0oAhozv_jz0jsyp_vR17ffoZfOn1V1HaNyxSuvAT5cbZt16tgs4WC1mI4C29b8I0mYdghpuRy8cjT7FZH0-Sl6GAvV0spg=)
[src-10] [lobehub.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEAdKn1pNFLTK_sn6uKUdD0pJTMd-4p4S2NL4V6f_Lb7JROMNH3EHrvpd6iY9uH4LXC-OrvcIpGwGItOJFiQ4Xa8ipyAx3eph-Mry6zorR1WpOkTs0efD3EILPGREx3GscQzVOxKg==)
[src-11] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGqT7sjK4_hC-fBcA9HBZAtC73jnhjlaCrhhxJ3zbwH4tFUeJCnVYlsHhRt2VC2tMbXS_kM65acjIesiwdgsLazJ78bd4VfzPBZujKIEZCxwsXlfQ-nVjhZ1mqWfmqtrpZeX_fqmIaP9SeLAfdCkYsAiScH4YgjFEf_)
[src-12] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGAmw5jvc3IHGvOH4Z6kaw7HX8jBgaLRr9mw-Lcn6IzK3rhMn--smO6Po0vp6FPG-2QhXq7SGMLPc1bSUskwLKFnNPEqRYfRYVMMftc_-Pbp4kmE96OKtqEwEPVDgjYMChnbMFnpQOQ0SgSC0AUF8SwoINSmfSJROWKDdTJbOr7kEw=)
[src-13] [crackingwalnuts.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGtZoVBwKFVRNguq8PSgWiwHnU__qTcBCITLMU2UdJyItINf2EpTahSDpqx0vqdxjcr7kB-ukPsQjjftCdj8p9yjEoF7mvqyQ5Y1OovyjbUAUWjjHmgS4-Xrqb70HAj9zCgZX3JzyeSxSz5oJeb-aI6wRM=)
[src-14] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQE5TXoIoLrTOKYxtClkfDMHV2y85mKWRTqn54wQw4tsG9cI-Y_97vTwNNGKGciz3_IrffYEGm34dkdLZewGRwT00xqphFL3FxNuKutlyaiBgAVWJfS7iDxGyganRIP_27C-IXT4GOupZg==)
[src-15] [christianmendieta.ca](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQG7LxjKhrZYNJdrv_staL4CzGoj417vm1PEzzgJABNI-AGsoTTn530w9ENmxUFkYUuoX8NiZAX-7jzD7gAqHyzsfgs27QWIDUxcABcwBHabWn5rZR_HDYuT0NhJJZKBxaPxpnmX09FG5zAw9Ud6w0RaNCcWnDWG8rUsYKY3PMG-2NWmK4ClQAXXI3K4kTnBkHne5_A0aX0qEAQ5JElkB8zbwsrvMNiM)
[src-16] [lobehub.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGjBPZow8oHa6InWxkc6DvNDUfYQ6AiTXHYsSel9_i1pe0J8OS6qHphvYzYoaIbrztSY7Ik03znQiJUkESwEMVdw4AAtIveqbccvf1sZT1XQsuFWMpY0fR_nXIJh8B8qC6y2P-R3b8xW8HSr6VX)
[src-17] [zenml.io](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEJa-xM1hWo3LMLMJK4UK5vEk7ob8yLJCXUoKcH4neBPr0n9pWOIlPiuico2-UU72fD35ydY7ZguaaellqPOsjQGwnkUsKVLcPpLPyTP6Lt6DAwDSkkUsiH-2ZOvBSauCA_6K0DnXpb9GI7d7Q7)
[src-18] [timfrohlich.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFSkbUWJYOIJvrozmqWN0ylccKNp0RqJZrhb3vY47s2TiIAa1r1Jz0MJPZV9BWPyQSlu0mDGJWzCxGx3yplK98GQ9w3Sa0f4RfYSJf887VPaSnCTNOgsxV4L_rxEgw90LdHNQQcCah_N0ZOb1kczbE=)
[src-19] [crackingwalnuts.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEZiU9pB1CMK3aFLPBIvviJI7ZjU36ctocdgxAvK3y1X7Qdo50i2-t-6BV4vVOYUgYYApvC-GTRM4oils5PQatcSYEMT0ZsTFXc_bub0a13ZfW_t8uOw51Xs5O9Gp06PsWn5B-mD84LN5TbHGfPLjrEIzg=)
[src-20] [skywork.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGXDxoxyv9doizwPDF43c9ETiNOHs2FtrayVxCGVP6sPe_qKY-tsHKWNh-Dc9T9KxoaLYExz8QjRC7AHuRcXVX1LqoC3_0Zt9buD0EGbIoOpK-_E3wcxPgDITb8V5oKSOk_zbI4i52_OdwC2QNWO5uAdpIcCaCTY-MbuW92L8WidC0f0C7-vBKkyN_fw3r2HPTAQhudro-EIDES1YY50XlZHI0=)
[src-21] [jetbrains.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQH5Ksfq9-bZpVZna6j7CRe3gwiD-u-CSLlpGJW1ugUkvq9vGeM3X6c0BFQdjvBE4QKzOOPmCuAa2sY1BtYwbAzCSaKethuc_waasvJ6l_6DOgybVgpSB5BjJ_hQr-dxZvX3jVvySUAkdNcs82V_twes9PEYxPSGIUzRZhDPPo1ybuaMNwfN)
[src-22] [scaler.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGfSrWn-ii-tJM-ZPQKt3cPgCDQOlIufYTEdOAm7KY5h-Qyk1ianNZ9Kd1clkvr0OXQ2D7rDYCcJrMH7afMstY6TPquNTbzCdytuGBbcxi2j227KoIsD9f1FNel20hGWXfpFOgSe89r59sA2DPTzSZeaU9THRUX_BM2NVQ8527WRg==)
[src-23] [dev.to](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQHVo23BcQH73SiFKwlc7hi6hinWAgrkZoDaFJ-vsP4vJVnYnShUdopy6YZBOytuW-LxJChCekL1r1Mozxql8H0qGtbpSM6_frOTlX-fGdxx5cWvxijbVYXsSwRG-my5LS6UrN25NnHekQh12wyj9t1-kORQr-vblNCIGoaZn3CA3g==)
[src-24] [medium.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFz-7csCI7wq9Ce6njRiFFW80Kb4kos1V9ZEVm0ERTX1YIqdj54kRjgI2svs3LIeQOswXnTMU-c-L6As7IiPDzOqtS7YmpkmNE2nj8zw3CySzT9XMj-xbHerzN-zOBrSq6MGIiT21quvnRcSwa7DYXEjVMtkg_iEK-p4nJqOyNleODnKM3u_2H7Q3WRz858fYnNZWt3iracfeoDwgxOVckVbmeLbfB9_lwoREWFj11P6NyBBS8t)
[src-25] [neo4j.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQE7CJ9tswLCYnO-H65_q0I3DPPrGvaMEn-aEcqi9NAP1ZWv-jkt8BV-VDod6t98bToFeY1mfPfzsrjdXAfvETN2qNZSZQf_UFCf9nedr_UwPEJfFuATDUoXndjN7FZLRo1jkKu9gezS8Yg9_ZrKnHuqwOGJ)
[src-26] [ortemtech.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQE5Zb7wZHESByPkDq3RYKl8-x-u50trM6L_PoigltPRLNO9F28iXDZNKe2aZcrSJWiwFyxGiIQkAkIdx8e4-sP_PTI1w3j0nv1JJO1d9IrMw732Zhye_WcpfsSLUw547IrfC230LKGZrUYWUnQ2s1BbbGNE4kRJOTgJJw==)

# Gemini 3.1 Pro Deep Search

**Topic:** agent_retrieval
**Question:** Reciprocal Rank Fusion RRF k=60 hybrid search pgvector BM25 tsvector ts_rank_cd pg_trgm weighted vs RRF candidate set size 50 100 200 before rerank 2026 best practice
**Model:** gemini-3.1-pro-preview
**Generated:** 2026-05-19 23:47
**Sources cited:** 15

---

## Synthesis

Enterprise retrieval-augmented generation (RAG) pipelines in 2026 increasingly consolidate hybrid search architectures into single-database systems like PostgreSQL. This shift actively displaces external sidecar search engines like Elasticsearch. The standard architectural pattern merges dense semantic retrieval via the `pgvector` extension with sparse lexical retrieval using native `tsvector` and `ts_rank_cd` functions. For fuzzy character matching to handle misspellings, engineers frequently deploy the `pg_trgm` extension. Advanced deployments requiring true statistical BM25 scoring deploy dedicated extensions like ParadeDB's `pg_search` or Tiger Data's `pg_textsearch`. 

When merging these dual retrieval streams, Reciprocal Rank Fusion (RRF) heavily outperforms weighted score combinations. Weighted combinations require brittle normalization logic because cosine similarity spans from -1 to 1 while BM25 scores scale to theoretically unbounded limits. RRF bypasses this vulnerability by calculating a unified penalty based purely on positional ranking using the formula `1 / (k + rank)`. The tuning parameter `k=60` -- originally established in a 2009 SIGIR paper -- remains the canonical industry standard because it durably flattens rank distributions and resists outlier distortions. 

Prior to feeding results to a cross-encoder reranking model, system architects must define the candidate set size. Current consensus dictates retrieving an initial candidate pool of 50, 100, or 200 documents per retriever. Fetching 100 documents serves as the optimal baseline for RRF fusion to ensure sufficient mid-list signal overlap. While fetching 50 documents boosts Recall@10 with a manageable latency penalty, scaling up to 200 documents reportedly prevents semantic false positives during the lexical filtering stage. Fetching fewer than 50 candidates starves the cross-encoder of context, and scaling beyond 200 documents triggers severe p95 latency degradation.

## Key Facts

* Single-database PostgreSQL setups now dominate hybrid search -- utilizing `pgvector` for semantic dense retrieval alongside `tsvector` and `ts_rank_cd` for exact-match precision [src-5].
* Trigram similarity matching via the `pg_trgm` extension is widely used to handle misspellings and fuzzy character matching [src-13].
* Teams requiring strict BM25 scoring deploy extensions like ParadeDB's `pg_search` or Tiger Data's `pg_textsearch` -- the latter of which reached its v1.0.0 release in March 2026 [src-13] [src-14].
* Weighted score combinations suffer from normalization vulnerabilities due to the bounded nature of vector cosine distances versus unbounded lexical scores [src-1]. 
* RRF discards raw scores entirely and computes a unified rank using `1 / (k + rank)` [src-3].
* The tuning parameter `k=60` remains the canonical TREC standard for RRF because it effectively resists outlier distortions [src-8] [src-10].
* RRF is executed natively via PostgreSQL Common Table Expressions (CTEs) in approximately 20 to 30 lines of SQL [src-7].
* A 2025 Databricks Mosaic AI benchmark indicated that feeding 50 documents into a cross-encoder boosted Recall@10 from 74% to 89% with an approximate latency penalty of 1.5 seconds [src-4] [src-11].
* Baseline RRF tuning targets 100 candidates to ensure mid-list signal overlap [src-9].
* Expanding the candidate set to 200 prevents semantic false positives, but sizes exceeding 200 allegedly trigger severe p95 latency degradation [src-12] [src-15].
* Efficient implementations execute vector retrieval against DiskANN or HNSW indexes while simultaneously running lexical retrieval using `plainto_tsquery` or `websearch_to_tsquery` within a single database transaction [src-2] [src-6].

## Open Questions

* What are the exact latency and accuracy differentials when strictly comparing 50, 100, and 200 candidate set sizes across varying hardware profiles?
* What are the specific computational dollar costs of operating cross-encoders at enterprise scale during the reranking funnel?
* Are there any pending legal challenges or compliance frameworks impacting how these dual-retrieval storage architectures process protected intellectual property?

---

## Sources

[src-1] [softwareseni.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFQrhFR7Zj5B6cUoR40R9N6GpnLmBaswjpGo0cCR4biiXZLcp1Vo6U2pQD_mxT49uTAGe-I4l_ovJIH56e5JM6lS4twOYQJ_XE2pr-C2ZkkO-FgaCd8b7V_tccvTJer2rMlhBvSz5Keicysnj0c87vD-kd-JGn2K8AO6zq28ka8G3ClsE2P7sHLDoNo8JyHj2DuWYbZR8LVzlXIsE_hogI=)
[src-2] [thebuild.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFPlDH889znu5No8aDDi_9a4rym0Dg0RF5dfGVqIB6T0yaLqPQCYyL5Py2y6SNs_Z528A7TVT7EX73VdLGMjNISAaY3Xr-gjd0NSpxJSHXZUWMfMGgo1hIdi44IfAlGddu06dyjR9t5Y8FidnfjSOrJGaCThrWhW3lRLHi0uFP8OPi_5Kc1VCjI2hlHQfORdSCNy9gXygflxCQqYUQxj6c9ZBgjaQ==)
[src-3] [dev.to](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEY-_38Wf3MoDnZPTH3qfMdcU-jjr7s9gqpdfj2gBi_Hbuc8Cfe2XNIZzTFzIoxtFWSXs4L5Zwqnwqi9f1k-TL3Jnu_WXaceJxrHZUNb9yARkX3a-WjcvJn95ub_rMAb8vkr--B-eK96GFK6GLEoIH-NcmHR7HGxNEBoefafGfq3_vfZ1Tm7sRJ8lgiOruuVQW-UyPkJc1hi3LQPZsfxuX1jkR23BdJ9e40J2U5KV8EO8KiEwMOUCwygUw=)
[src-4] [callsphere.ai](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEZoZ9ok7jiuiHo5HXPkyJ74Az6RTx74ER6w_UITd8sV4xGu22I3V8DOyLyy7gOwD5blsAlM6qERH-p2rvcOshbTM9p7GO-5i38ablebgbMIMaDJPWLyb5iH9VWonfZpEjazLaH8gVdUsMH720Fftd9sPBpHFc34OVap4QVfU8C0HM=)
[src-5] [sogo.dev](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFyVlpTer_jzycrrjtf1Sy5DLBO8tholG4CgShvZuCDZ8Kb2j7oNG6ddm61LG3uDF0XpZ5CF5QNMlGMPjRLDYNIfEGpiPTvxVnsjdXDIU_Q539oOTaE1ldAOp5Nz92fQeyARfUwrYmsgrqACA==)
[src-6] [alibabacloud.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEsQyIhm8t5fKt7lgTlQ5oU7c6_W00_sxPA2kLeUNm6UZECSZTbrB-PFjOzUmaxiu8fuD-Uzl0a8evEts8ffq3064iGbxBL_aqRNo5Nl_AmjcKWY_se7dY89alhoGg-mquZmppTlbPEttZQiHi1k60A57spuVM1vGbYYj6jjgy6fztgFRFn)
[src-7] [dev.to](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGbAFkpGWPPQpSeq61cLnBQsJLkkSuhoxOBh0rioITfu9zmrsW4bZCJEXgfCKvh0TkJryp1dKT68PzD-v6Gy7-jSDQm3AN3oqvSmLc6KKPqD5auppA6JQFGSDoMEK4Wmtn9pgU=)
[src-8] [lockedinai.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQE0yx2kvz2Fu521CbLYyRwXXQ6S0QSz2jUU70ke8mIYluKXiFdQcgh65dSatc2joQFgUATlVqFFE5T0Pn4CXoTHPgq1Hl1YyPqTIKB6QHx-uIflbWHFjVwqwdRSH0bUi4FQpIoaLcFOqFzZtMTBFmFO21IUNR1KPI027g==)
[src-9] [daily.dev](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFuGsHcdh_SjEeBDz3We6HJdvCB914Pxo_tc5qxUE6xV3rSiZZfPBRSfg4VoOdI4KKttbn5kNgDdgzfMyNsPvPYaColK7_ruC9dkCViDIPn-EW8FoShmjhmqYCckM52G__oNqMxdLFRC6kTF3uht8JiotOLq3ALgHqjXBQskzOnjxMZur1xMZWW1hHnKM_G4005jmE3B-kTkz07sg==)
[src-10] [github.io](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFtJ5nGvdqtu7Q74doRLqQw7y7286PZ21amEXgMuJIQXtsvl4cBkdKg2m8NEt0lpU4WG-9WNGdAwQzw1WxU58by_PUk_pvKVXTSR101sMe3DwP-xkZfsFURYuqpLVnf_9txuAoXv23GVeOOQqThy-rYRCJWu_7CjA==)
[src-11] [futureagi.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFVB-1Lk9uT2hZxvhPkhPAL5EOWzLpY3pexCKu1nLB42F-fra93Y8Aia-MrNzUZYPVC9XLhqAae9i1yhQf9DQHTy1uw6R0VDLvvlKR9gkRwjizOxmaUNlesWjRUd3M1cctZnzhT-KJc5r3kOYIm1Pj_)
[src-12] [synthimind.net](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEJCYvn6BiDBENCxQC_1YegRukJO6VYenn28mitTmhEnPluMZZW3jhMASatGIM-sIwUjQSTyJA9BZca28ukFKDLEKKk4h_AvBZPBYtys5kmlIPz-Fe0BeFttC0Ae_0mlF9lZ3xQfIDXnhnVPHAPO4L3BqCZiCjc_wM=)
[src-13] [paradedb.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEyBh-9FChrIuqXxBaGbRdCYWsKGXIrmQ8mEMUL0HJal8o2iPOKnernJ5Un8_rbnc-nIBTS63jN-SqSAKWDZletzEtRPfj2lZ4Hiw6i5rukmvHR6euT88vPgbC9kuRTbJBguUsJ-i0eJAGgYS5cvhlzl4qHRkK-OH0-7lq6ly9LPQ==)
[src-14] [medium.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEndNcsVZ2ZYzSb-A9kfiFO_1ZFylaaXHR7aNc2Qqf_niJk2wPRbZ6IP7AKACk1iIbcbw8BU7UHd6M2f1W3FxuvEIX6Pq9t95smoPt87Kpi_tsOkLENedcKpZbJG17Q47ASv8nH4_UfUrWTTA5aJwCUnprUBTCcNu13GcA9hEG3Et6Zx8t1rrQY48asVgWHQvu8I9I=)
[src-15] [reddit.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFpmlWXJ0gHRd5RIPCXzqRqyDs60qIgyU3jbJqBtQQ2v0ccWsgoBhpKeONyz8MJ6zMs25IPtZFJBsg0wu9JIPKuILpZ5Dh9WvJgiy9SXM9Tufvo3gtfBMt_-k3ZwGonwkf80crVH0ISJDrMikPK_2dptYfB63rm7HmCTGOqkRXRKEAmhbHc89w2Ph_S7IecMmOtI-GlMOSMwQ==)

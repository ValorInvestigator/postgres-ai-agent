# Gemini 3.1 Pro Deep Search

**Topic:** ingest
**Question:** Anthropic contextual retrieval September 2024 implementation chunk preprocessing late chunking Jina embeddings RAPTOR parent-child chunking optimal chunk size 512 1024 tokens with rerankers
**Model:** gemini-3.1-pro-preview
**Generated:** 2026-05-19 23:46
**Sources cited:** 8

---

## Synthesis

In September 2024, Anthropic released a preprocessing methodology named Contextual Retrieval to address context dilution in Retrieval-Augmented Generation systems [src-1]. Traditional ingest pipelines split documents into isolated segments. This often strips text chunks of their broader meaning. Anthropic mitigates this by using a large language model to generate brief document summaries. These summaries are prepended to individual chunks prior to indexing [src-2]. Early internal testing indicates this approach significantly reduces retrieval failure rates, especially when paired with modified algorithms like Contextual BM25 and rerankers [src-2].

Alternative preprocessing strategies are also emerging to preserve document context without relying on generated summaries. Jina AI introduced late chunking in a 2024 paper [src-6]. This technique processes entire documents through long-context transformers before applying predefined chunk boundaries [src-6]. Other vendors are rapidly iterating on global context encoding. Voyage AI recently claimed its proprietary models outperform Jina AI's late chunking metrics [src-8]. Meanwhile, engineers continue to deploy structural frameworks like RAPTOR and parent-child chunking to optimize retrieval granularity [src-4].

## Key Facts

*   Anthropic's Contextual Retrieval leverages a large language model to generate a 50 to 100 token summary of a document, prepending this context to every chunk before it enters the index [src-1].
*   Anthropic reportedly reduced its top-20 chunk retrieval failure rate from 5.7% to 3.7% using Contextual Embeddings alone [src-2].
*   The failure reduction rate allegedly increased to 49% when integrating Contextual BM25 -- a modified term frequency-inverse document frequency algorithm -- and reached a claimed 67% with the addition of a reranking step [src-2].
*   Alex Albert, Anthropic's head of Developer Relations, stated on September 19, 2024, that the system depends heavily on prompt caching to control the financial and computational costs associated with full-document processing [src-3].
*   Jina AI detailed late chunking in a 2024 paper, proposing a method where full texts pass through a long-context transformer -- such as jina-embeddings-v2-small -- before tokens are segmented and processed via mean pooling [src-6].
*   Voyage AI claims its voyage-context-3 model outperformed context-agnostic models like OpenAI-v3-large by 14.24% and Jina-v3 late chunking by 23.66% on chunk-level retrieval tasks [src-8].
*   Structural techniques like RAPTOR -- Recursive Abstractive Processing for Tree-Organized Retrieval -- and parent-child chunking remain standard options for balancing retrieval precision and generation quality [src-4].

## Open Questions

*   How do different chunk sizes -- specifically 512 versus 1024 tokens -- impact retrieval accuracy when deployed alongside rerankers and contextual embeddings?
*   Can independent testing verify the aggressive performance margins Voyage AI claims over competitors like Jina AI and OpenAI?
*   Will the reliance on prompt caching for Anthropic's Contextual Retrieval present scaling bottlenecks or cost overruns for high-volume enterprise deployments?

---

## Sources

[src-1] [infoq.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEzyYjbc5gIWbQXiwUMuOC8aGPIfqMxAPgh_uuUhI6QCs29IQsggwcjIUl05IzaTMe5-LsgQkPEza5ii_1RjqJSjr_g3sbNVcpY9lGBfmGLjts3Dc42sxUiik38XTdG3g0IHQynlDVKaTnLBKg5FSu7MAAnVl0MCSOlYLX7)
[src-2] [maginative.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEQVFTmNxqL7Ek1AX5Z9B-t3qjE0NnBitwCtrdeoH3JTNbHLdn9uJHdi03tzKQqrVKxdlu6zbjEMP3UxU_Ptyz3QdaOJ470NnmiRnhh_u64hQtIJtvQhQhl1KE6PLBUXfLm0ipgMR8A0kiblEfDkdo-3GDmlgCcn48oaUROQYMzl4CEqkFBOjM4Z1H_y28RuyRixw-VvJJtK_wxbv4enkvHfYDZ)
[src-3] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQH8C2nNRkFJG--bHpOX2FAvaIxawVlPj9p8s3NRt-7I0qWLIRVRrfAjvemEJSTiDBGPiQ9fS5_JXYgwj63yj4-pvld4GuDzyZU4295JQWmfZwMbskWo-XeWZ274hEbKWhs34Z_DIrWyUWeAQIsq8scQluaT_Vkwzjje5dTyY_Qcj6odqZFqejAvkXko6ketnLgNElFwpwaXM-IVKHYqqpgQZPV-f00gTWJJ)
[src-4] [atlan.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEkgbYq6w3T0aDadlVmPWPqMFS8vVc59-ZDajFhWbBjmiHAbjLrzgTKAkKZ9CTtnA8SSp6RCGuY5CqR1R5g1EjNu9nBtqQD49CNJR5zvSiyjeeH5AM-efW8Bson1rLE7KxnLqptUEWU4Bk=)
[src-5] [medium.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQHw899WAKhbtD31lqQjmwprZQ-V7omxNl4BRbmzDivS04oyZ25o9F2ntFASaqU23o8J-bupPHwhU1DEmIUqRWsQg4vN4Z_MVhHsJPFa5nm7Vo8pW3scSxqZwZCkaF1UlKu5jqXYwK6gwO3FmWfX6wsoPZZLzhCpIrkv_KGCFJGzqgmVoA==)
[src-6] [arxiv.org](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQE_hKk9oMcn0t6cyq9fS7x9TzrNY_f7rOYjki0hmZPWAE_9c2BfHGCEy53hMl8_qFNGZAtf6MHRaCOdmXa8OIIpjlwzoBNhgJMe4Q-tfxHt3DY-brQT6tStyCA=)
[src-7] [themoonlight.io](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQHfwAYJEIIZXx9m69nC4dvfwO4tpv8WWK9sitHZoEvZhi4ltb1btPmkCvC999AVJNx80qLQml9ieBijr612-x5ruF5q1u6BwgkjJV8wrUgX3vsONv_7yOY8lyJfpqxbi5E0uLhZ469wotKyzeyQOzgeaqRyw-Hv2H3VT35oefXekVgn_1rHiXsMLCmznVi6IIx5-cXyiu9FeKOENLxSiJmygeZgDMiJK_a6dxHpAA==)
[src-8] [voyageai.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFucFFV3aJ0cuWGpv9fEVJRTsWH3Dyl522O-J3XCPuwltBsoPqaZjGwh9FvnARdTz2b07pw0TL5KGeZW5XIx3Aya8moKBpklcytbdMG3gl47qRMAiiiEWrvA05sTRRqIUTufP-EB6eCqRKA5KnRX55C)

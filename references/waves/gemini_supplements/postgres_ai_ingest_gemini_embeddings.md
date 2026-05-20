# Gemini 3.1 Pro Deep Search

**Topic:** ingest
**Question:** best embedding models 2026 MTEB leaderboard Voyage voyage-3-large voyage-context-3 Cohere embed-v4 BGE-M3 Stella mxbai Nomic Qwen3-Embedding text-embedding-3-large comparison retrieval
**Model:** gemini-3.1-pro-preview
**Generated:** 2026-05-19 23:46
**Sources cited:** 15

---

## Synthesis

The mid-2026 landscape for text embedding models features intense competition between proprietary APIs and open-weight architectures. The Massive Text Embedding Benchmark (MTEB) continues to serve as the baseline for evaluating retrieval models across 56 tasks. Proprietary models like Voyage AI's `voyage-3-large` and open-weight alternatives like Alibaba's `Qwen3-Embedding-8B` currently dominate the top tier of the leaderboard. Commercial providers such as OpenAI and Cohere maintain strong market presence by balancing cost, context length, and multimodal capabilities. Meanwhile, the open-source ecosystem provides powerful alternatives like `BGE-M3`, `Stella`, and `Nomic Embed v2` for users prioritizing hybrid retrieval, edge deployment, or specific parameter constraints.

Despite the heavy industry reliance on MTEB rankings, researchers indicate that aggregate benchmark scores do not reliably predict retrieval performance in specialized domains like finance. Consequently, the choice between commercial APIs and self-hosted open models increasingly depends on operational scale and specific data constraints rather than raw accuracy. Commercial endpoints offer cheaper and easier integration for low-volume applications. Infrastructure costs dictate that organizations must process tens of millions of embeddings monthly to justify the hardware expenses associated with self-hosting open models. Furthermore, while companies like Voyage AI focus on premium pricing for top-tier recall in technical fields, unconfirmed models like `voyage-context-3` remain absent from official leaderboards, leaving developers to rely on community speculation.

## Key Facts

* Voyage AI's `voyage-3-large` outputs 1024 or 2048 dimensions, scores 70.32 on the MTEB, and costs $0.18 per one million tokens [src-4].
* OpenAI's `text-embedding-3-large` remains a widely used baseline scoring 64.6 on the MTEB at $0.13 per million tokens, featuring Matryoshka representation for truncation down to 256 dimensions [src-1].
* Cohere's `embed-v4` achieves a 65.2 MTEB score at $0.10 per million tokens and distinguishes itself with a 128,000-token context window and native multimodal embedding for text and images [src-2].
* Alibaba's `Qwen3-Embedding-8B` achieved a 70.58 on the multilingual MTEB and supports over 100 languages under an Apache 2.0 license [src-9].
* The Beijing Academy of Artificial Intelligence developed `BGE-M3`, which scores 63.0 on the MTEB and uniquely supports dense, sparse, and multi-vector hybrid retrieval across 100 languages with an 8192-token context [src-10].
* Nomic Embed v2 and its predecessor `nomic-embed-text-v1.5` operate on just 137 million parameters, allowing CPU-only local execution while retaining an 8192-token context and Matryoshka compression down to 64 dimensions [src-13].
* The open-weight model `Stella` is highly ranked for commercial use and is available in 400M and 1.5B parameter variants [src-14].
* The `mxbai-embed-large-v1` model utilizes 335 million parameters and is capped at a 512-token context length [src-14].
* Claims regarding a `voyage-context-3` model remain unconfirmed, as September 2025 community discussions noted its explicit absence from the MTEB leaderboard and lack of official performance metrics [src-8].
* A 2025 study evaluating 15 models across 64 financial datasets on the FinMTEB benchmark found statistically insignificant correlations between general MTEB rankings and specialized financial retrieval performance [src-12].
* Self-hosting models like `BGE-M3` on AWS A10G GPUs at approximately $0.75 per hour becomes economically viable only when processing volumes exceed 10 to 15 million embeddings per month [src-15].

## Open Questions

* Will Voyage AI release official documentation or verifiable performance metrics for the unconfirmed `voyage-context-3` model?
* How will the documented discrepancies between general MTEB scores and domain-specific benchmarks like FinMTEB alter future evaluation standards for specialized retrieval tasks?
* Can highly compressed, edge-optimized models like Nomic Embed v2 close the recall gap with larger parameter architectures like `Qwen3-Embedding-8B` in complex multilingual environments?
* Will commercial API providers further reduce pricing to maintain their competitive advantage against the rising accuracy and accessibility of open-weight models?

---

## Sources

[src-1] [codesota.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEpjHEnfGkhCcWkRR0YllNw2ocCt6iMunjB_2yXxKSuB5CWXoh40xMUzR3MbAu48bt92TXA66Zn1v-YD55td8MBYVwrMnhEtXNHyvj47kj2JjjYsZWD-0N4SofMlnuNwnUgzA==)
[src-2] [pecollective.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQHB-cTE5l6ihFA-E8cqWsJJD2I4ApVjknBpLx0Vih2qKLyKh_eZpGxS_S5VzdVOeGfauVXp7rzn1hOE_ZfufZynizyDnVIE9vpDjfJypwLW3Fhpi2S5kFH-n_9qsKvmMaZIe6fYxaRYS2sTNpofyqTu)
[src-3] [pecollective.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFBsuSQpdway55xWZIyRKu-kcgWdFeVFd9SOQhjIZtpM02Fe8xL15X8EzERF4IuERmq9g9zIOw8vpz61Q80sxsHVzkFDOJSuVL5dbpW2iUjuUBJ3wJ6358m3Uw1HYD6WHwiGKAvHfhExuoymmDOzeW_sDyDjLHSyawz)
[src-4] [voyageai.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQG63QxomHLMKyDs-SPcyQ2jzLJVREV_qUD7dA8RlNLuZPhxzGuYd-2dN2IT8FTurbhWmNtLVWaRmyytUjgT0HrGb0-6gBGeKHdz4JkRCxlAcWWTvKXI-SfYPcjszKquXmqTWzMp)
[src-5] [ailog.fr](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQF8VeePDjJn-HUIr00DQ30iSQD44HheoSJs5d4WsROCWZvQVwZ39TtbkW4BuglCkq-9bcAB02LXrgA19_aU_8zcVcyRkY_AvSXghFHAGB4qJHKXh_85ZYE-szC8Llo9yPuRtAz2680X_P1fwHo1ab1_cyCMt4XyV_E=)
[src-6] [ailog.fr](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFfiXiC7Ski0jsfEpWPnkfPdnqKLtSS1S8Qzb3Voz25DkN1IAxOZYii0zPaSLk-0OnaIe8p11Qh4meRD1KHi1rRicmru3wRBF2Nb1ZpVG5BqAnV4Jk5XHjI7rtnTZMyPYKJiCaUYqybs5DMki5YGEBhkX8=)
[src-7] [azure.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQES6bCh33vB9Z-01s2HxCznKwkJh-rIrgr_EMF0lMK1uQj8jbrsCDAigeYhpAZE3_fRLxYroloEvSEbnd2AvBwUV4azQMOotM6onI16MahchuI84T0ovMlKfXJzakv6E_AP9b2CpMJQ6W-_)
[src-8] [reddit.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQEutXd2s0w6ABgqwwa6AKB4_rNqwOF0uZeEx0BupO_L0wcISbxFopilWLhlTr4Uss3ldgKiglDHwwGLQKyj-aclZfCr6V7WeojokLaapH89M031-2xqRHYkyIPPcVq5niFnJUgGHuuIIAeg5mN3tU0iJCcFzo6LWPL-2gnaewO1exq_oN4XwVVTvQUF1ZkYVkEpxQsHjA==)
[src-9] [github.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGL9fFYujG-KboPA5sU4K13cfd4NTgYamTrRxE_pxR7SB9xgQSpIy8BT99yid00oYtDmkJBPHZ41bo7Y0tBHKnXDFXwy5eZVnmy0XiClpfdgDuHpje5LwvyqxcQi-F1cK68tTD0)
[src-10] [huggingface.co](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQG87q3pjPm-bDY6wQIR1DrhvXBd9902zQmlNP10MhlYfHOayoxx5WWtM1aAzl-dgg0MXMS1s2TwMyYjf-7qBQtwPBiwO9AC5q4ZCmDtEF6yIo2D3f7upVrOOId4nobWyzNQC6VsMS3ZzWY=)
[src-11] [machinelearningmastery.com](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFeptgAA1m2p17nhJ8wD_0itk322IgHcjw9h6S0klX0q3oidVKYANBRiRB6GOsboeu6-hftIpzcpCD8I53pmDCXfG4YSwvdIYIwo50mSCxXSwb-YEH1N2h1Qt5Km64YVUgT6W-iB3XjAxzpZZhMgYNA44Klh0LalLeh3he4mGiTpA8J6qLVle8nqds0u-3iIixZBRvskTqcdnpC8R4=)
[src-12] [aclanthology.org](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGSEja-9G63cXgstjQ5gMXgPRup5jusqb3FfI27EPZcCs1-J2k9V1gaWVLpWzaXAkRR8qzP2szR7WHiy2X1Irkhx8q3AMrfSs7ydirwgVmX9SuaKLKaJqZ4RTe_fPFUWjSxHkJfM7hNFD0LeQjhq-M=)
[src-13] [dev.to](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQGXQuOBEOLhVr_AfA67aiI3WN3e2zD8blG5_zP8FDKfQX1ot6QcQ_VJqA9HOSOXalLV72p6tZp3_TXTXpNaKoae70MR5SRDODpU556CWQjQjf4OQiocRWvZHGEVEoKNWOSkduimtvAkxArxSU36e36_Q1sL9bLOn-GICkP06wF4KFbC8dDDoxn5XIsHLkCIdSw_SGw=)
[src-14] [huggingface.co](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQH-tQvM9dsy2-vp1SdTPouGwShEygVw9LknHLx_78FcXzGh0Cd4Ieo-OZrBZpiX7T_SWXpppvMXG2JoZRIKWvIRlr7Src0Bwy4ZS9kqT407qPx7KsMwBmiX8sjC34ILnRnGRxe02tEvK-Vlskz6uzJB749zpgRozJtvm4EvQg3ek8JR1l7SaOsIyCMU2Xz9y7SfOJjdUDii-_k=)
[src-15] [ranjankumar.in](https://vertexaisearch.cloud.google.com/grounding-api-redirect/AUZIYQFz2Py0PoahTGS8rLiX1LkrmDdzJ2dRLrxBzPCD4gfA-td540TYexL1ISH9u5-_NpMUjXQH31bnYVGCoqPzXb0eUj6EX7HwL0RU_o136I6e4vWMpAySe1i9vKWXVPoN4hGuMmHkmWkRwqva8B8A6--qV4iGBFDDvls58ok9wPen0hc=)

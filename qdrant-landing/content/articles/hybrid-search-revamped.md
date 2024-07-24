---
title: "Hybrid Search Revamped"
short_description: "Merging different search methods to improve the search quality was never easier"
description: "Qdrant 1.10 introduces a new Query API to build a search system that combines different search methods to improve the search quality."
preview_dir: /articles_data/hybrid-search-revamped/preview
social_preview_image: /articles_data/hybrid-search-revamped/social-preview.png
weight: -150
author: Kacper Łukawski
author_link: https://kacperlukawski.com
date: 2024-07-21T14:24:00.000Z
---

It's been over a year since we published the [original article](/articles/hybrid-search/) 
search system with Qdrant. The idea was straightforward: combine the results from different search methods to improve 
retrieval quality. Back in 2023, you still needed to use an additional service to bring lexical search 
capabilities and combine all the intermediate results. Things have changed since then. Once we introduced support for
sparse vectors, [the additional search service became obsolete](/articles/sparse-vectors/), but you were still 
required to combine the results from different methods on your end.

**Qdrant 1.10 introduces a new Query API that lets you build a search system by combining different search methods 
to improve retrieval quality**. Everything is now done on the server side, and you can focus on building the best search 
experience for your users. In this article, we will show you how to utilize the new [Query 
API](/documentation/concepts/search/#query-api) to build a hybrid search system.

## Introduction to the new Query API

At Qdrant, we believe that vector search capabilities go well beyond a simple search for nearest neighbors.
That's why we provided separate methods for different search use cases, such as `search`, `recommend`, or `discover`.
With the latest release, we are happy to introduce the new Query API, which combines all of these methods into a single 
endpoint and also supports creating nested multistage queries that can be used to build complex search pipelines.

If you are an existing Qdrant user, you probably have a running search mechanism that you want to improve, whether sparse 
or dense. Your system will act as a baseline for further experiments, so you have a reference point to compare the new
search methods with.

### Available embedding options

Support for multiple vectors per point is nothing new in Qdrant, but introducing the Query API makes it even
more powerful. The 1.10 release brings support for the multivectors, which allows you to treat lists of embeddings 
as a single entity. There are many possible ways of utilizing this feature, and the most prominent one is the support
for late interaction models, such as ColBERT. Instead of having a single embedding for each document or query, this
family of models creates a separate one for each token of text. In the search process, the final score is calculated 
based on the interaction between the tokens of the query and the document. Contrary to cross-encoders, document
embedding might be precomputed and stored in the database, which makes the search process much faster. If you are
curious about the details, please check out [the article about ColBERT, written by our friends from Jina 
AI](https://jina.ai/news/what-is-colbert-and-late-interaction-and-why-they-matter-in-search/).

![Late interaction](/articles_data/hybrid-search-revamped/late-interaction.png)

Besides multivectors, you can use regular dense and sparse vectors, and experiment with smaller data types to reduce
the use of memory. Named vectors can help you store different dimensionality's of the embeddings, which is useful if you 
use multiple models to represent your data, or want to utilize the Matryoshka embeddings.

![Multiple vectors per point](/articles_data/hybrid-search-revamped/multiple-vectors.png)

There is no single way of building hybrid search. The process of designing it is an exploratory exercise, where you
need to test various setups and measure the effectiveness of each of them. Building a proper search experience is a
complex task, and it's better to keep it data-driven, not just rely on the intuition.

#### Measuring the effectiveness of the search system

None of the experiments makes sense if you don't measure the quality. How else would you compare which method works 
better for your use case? The most common way of doing that is by using the standard metrics, such as `precision@k`, 
`MRR`, or `NDCG`. There are existing libraries, such as [ranx](https://amenra.github.io/ranx/), that can help you with 
that. Obviously, we need to have the ground truth dataset to calculate any of these, but curating it is a separate task.

```python
from ranx import Qrels, Run, evaluate

# Qrels, or query relevance judgments, keep the ground truth data
qrels_dict = { "q_1": { "d_12": 5, "d_25": 3 },
               "q_2": { "d_11": 6, "d_22": 1 } }

# Runs are built from the search results
run_dict = { "q_1": { "d_12": 0.9, "d_23": 0.8, "d_25": 0.7,
                      "d_36": 0.6, "d_32": 0.5, "d_35": 0.4  },
             "q_2": { "d_12": 0.9, "d_11": 0.8, "d_25": 0.7,
                      "d_36": 0.6, "d_22": 0.5, "d_35": 0.4  } }

# We need to create both objects, and then we can evaluate the run against the qrels
qrels = Qrels(qrels_dict)
run = Run(run_dict)

# Calculating the NDCG@5 metric is as simple as that
evaluate(qrels, run, "ndcg@5")
```

### Fusion vs reranking

We can, distinguish two main approaches to building a hybrid search system: fusion and reranking. The former is about 
combining the results from different search methods, based solely on the scores returned by each method. That usually 
involves some normalization, as the scores returned by different methods might be in different ranges. After that, there 
is a formula that takes the relevancy measures and calculates the final score that we use later on to reorder the 
documents. Qdrant has built-in support for the Reciprocal Rank Fusion method, which is the de facto standard in the 
field.

![Fusion](/articles_data/hybrid-search-revamped/fusion.png)

Reranking, on the other hand, is about taking the results from different search methods and reordering them based on
some additional processing using the content of the documents, not just the scores. This processing may rely on an 
additional neural model, such as a cross-encoder which would be inefficient enough to be used on the whole dataset. 
These methods are practically applicable only when used on a smaller subset of candidates returned by the faster search 
methods. Late interaction models, such as ColBERT, are way more efficient in this case, as they can be used to rerank
the candidates without the need to access all the documents in the collection.

![Reranking](/articles_data/hybrid-search-revamped/reranking.png)

Ultimately, **any search mechanism might also be a reranking mechanism**. You can prefetch results with sparse vectors 
and then rerank them with the dense ones, or the other way around. Or, if you have Matryoshka embeddings, you can start 
with oversampling the candidates with the dense vectors of the lowest dimensionality and then gradually reduce the 
number of candidates by reranking them with the higher-dimensional embeddings. Actually, nothing stops you from 
combining both fusion and reranking. 

Let's go a step further and build a hybrid search mechanism that combines the results from the 
Matryoshka embeddings, dense vectors, and sparse vectors and then reranks them with the late interaction model. In the 
meantime, we will introduce additional reranking and fusion steps.

![Complex search pipeline](/articles_data/hybrid-search-revamped/complex-search-pipeline.png)

Here is how a corresponding query would look like in Python:


```python
from qdrant_client import QdrantClient, models

client = QdrantClient("http://localhost:6333")
client.query_points(
    "my-collection",
    prefetch=[
        # The first branch of our search pipeline retrieves 25 documents
        # using the Matryoshka embeddings with multistep retrieval.
        models.Prefetch(
            prefetch=[
                models.Prefetch(
                    prefetch=[
                        # The first prefetch operation retrieves 100 documents
                        # using the Matryoshka embeddings with the lowest
                        # dimensionality of 64.
                        models.Prefetch(
                            query=[0.456, -0.789, ..., 0.239],
                            using="matryoshka-64dim",
                            limit=100,
                        ),
                    ],
                    # Then, the retrieved documents are re-ranked using the
                    # Matryoshka embeddings with the dimensionality of 128.
                    query=[0.456, -0.789, ..., -0.789],
                    using="matryoshka-128dim",
                    limit=50,
                )
            ],
            # Finally, the results are re-ranked using the Matryoshka
            # embeddings with the dimensionality of 256.
            query=[0.456, -0.789, ..., 0.123],
            using="matryoshka-256dim",
            limit=25,
        ),
        # The second branch of our search pipeline also retrieves 25 documents,
        # but uses the dense and sparse vectors, with their results combined
        # using the Reciprocal Rank Fusion.
        models.Prefetch(
            prefetch=[
                models.Prefetch(
                    prefetch=[
                        # The first prefetch operation retrieves 100 documents
                        # using dense vectors using integer data type. Retrieval
                        # is faster, but quality is lower.
                        models.Prefetch(
                            query=[7, 63, ..., 92],
                            using="dense-uint8",
                            limit=100,
                        )
                    ],
                    # Integer-based embeddings are then re-ranked using the
                    # float-based embeddings. Here we just want to retrieve
                    # 25 documents.
                    query=[-1.234, 0.762, ..., 1.532],
                    using="dense",
                    limit=25,
                ),
                # Here we just add another 25 documents using the sparse
                # vectors only.
                models.Prefetch(
                    query=models.SparseVector(
                        indices=[125, 9325, 58214],
                        values=[-0.164, 0.229, 0.731],
                    ),
                    using="sparse",
                    limit=25,
                ),
            ],
            # RRF is activated below, so there is no need to specify the
            # query vector here, as fusion is done on the scores of the
            # retrieved documents.
            query=models.FusionQuery(
                fusion=models.Fusion.RRF,
            ),
        )
    ],
    # Finally rerank the results with the late interaction model. It only 
    # considers the documents retrieved by all the prefetch operations above. 
    # Return 10 final results.
    query=[
        [1.928, -0.654, ..., 0.213],
        [-1.197, 0.583, ..., 1.901],
        ...,
        [0.112, -1.473, ..., 1.786],
    ],
    using="late-interaction",
    with_payload=False,
    limit=10,
)
```

The options are endless, new Query API gives you the flexibility to experiment with different setups. Obviously, **you
rarely need to build such a complex search pipeline**, but it's good to know that you can do that if needed.

## Conclusion

The new Query API introduced in Qdrant 1.10 is a game-changer for building hybrid search systems. You don't need any
additional services to combine the results from different search methods, and you can even create more complex pipelines
and serve them directly from Qdrant. 

Our webinar on *Building the Ultimate Hybrid Search* takes you through the process of building a hybrid search system 
with Qdrant Query API. If you missed it, you can [watch the recording](https://www.youtube.com/watch?v=LAZOxqzceEU), or 
[check the notebooks](https://github.com/qdrant/workshop-ultimate-hybrid-search).

<div style="max-width: 640px; margin: 0 auto; padding-bottom: 1em"> <div style="position: relative; padding-bottom: 56.25%; height: 0; overflow: hidden;"> <iframe width="100%" height="100%" src="https://www.youtube.com/embed/LAZOxqzceEU" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen style="position: absolute; top: 0; left: 0; width: 100%; height: 100%;"></iframe> </div> </div>

If you have any questions or need help with building your hybrid search system, don't hesitate to reach out to us on 
[Discord](https://qdrant.to/discord).
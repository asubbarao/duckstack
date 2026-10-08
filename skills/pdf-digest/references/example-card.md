# Inference Engineering — Philip Kiely
_259 pp · 432.0×648.0pt · digest of 156 headings · `> lead sentence`, `# tf-idf terms`_

## Contents

- INFERENCE ENGINEERING · p1 (pdf 3) · 998w
  - Table of Contents · p3 (pdf 5) · 0w
  - Preface · p9 (pdf 11) · 998w · 3 fig
    > Inference engineering, on the other hand, is still in its infancy. Inference engineers work across the stack from CUDA to Kubernetes in pursuit of faster, less expensive, more reliable serving of gene
    # closed, products, companies, builders, world, expensive
- Chapter 0: Inference · p15 (pdf 17) · 1100w
  - Inference · p17 (pdf 19) · 1100w · 3 fig
    > In last decade’s machine learning (ML) boom, hundreds of thousands of data scientists and ML engineers became familiar with the full lifecycle, both training and inference, for ML models
    # infrastructure, problems, speech, lifecycle, silos, abstraction
- Chapter 1: Prerequisites · p23 (pdf 25) · 2573w
  - Prerequisites · p25 (pdf 27) · 298w · 1 fig
    > Inference engineering adds speed and scale to AI products by optimizing production serving of generative models
    # product, demands, fulfill, know, requirements, clear
  - 1.1 Scale and Specialization · p26 (pdf 28) · 271w · 1 tbl
    > There are two ways that you can add AI models to your product: 
    # dedicated, shared, switch, million, closed, versus
  - 1.2 About Your App · p27 (pdf 29) · 714w
    > Every inference engineering decision you make will be downstream of your use case
    # coach, vertical, ai-native, apps, case, customer
    - 1.2.1 AI-Native Applications · p28 (pdf 30) · 72w · 2 tbl
      # breadth, category, emerge, smarter
    - 1.2.2 Online versus Offline · p29 (pdf 31) · 241w
      # offline, online, catalog, jobs
    - 1.2.3 Consumer versus B2B · p30 (pdf 32) · 210w
      # consumer, businesses, compliant, apps
  - 1.3 Model Selection · p31 (pdf 33) · 908w
    > All else being equal – hardware, runtime, optimizations, architecture – inference on a smaller model with fewer parameters will be faster and cheaper than inference on a larger model with more paramet
    # worth, cheaper, find, frontier, smaller, equal
    - 1.3.1 Model Evaluation · p31 (pdf 33) · 245w
      # evals, intelligence, evaluation, against
    - 1.3.2 Fine-Tuning for Domain-Specific Quality · p32 (pdf 34) · 167w · 1 fig
      # fine-tuning, domain, coding, databases
    - 1.3.3 Distillation · p33 (pdf 35) · 291w · 1 fig
      # distilled, distillation, deepseek-r1, behavior
  - 1.4 Measuring Latency and Throughput · p35 (pdf 37) · 382w · 1 fig · 1 tbl
    > The two most common performance metrics for LLMs are TTFT (time to first token) and TPS (tokens per second)
    # metric, ttft, metrics, service, chatbots, equates
    - 1.4.1 Latency Percentiles · p36 (pdf 38) · 119w · 1 fig · 1 tbl
      # outliers, average, experience, comparing
    - 1.4.2 End-to-End Metrics · p37 (pdf 39) · 90w
      # end-to-end, metrics, distinction, measurement
- Chapter 2: Models · p39 (pdf 41) · 6081w
  - Models · p41 (pdf 43) · 304w
    > Inference engineering is the practice of making generative AI models faster, less expensive, and more reliable – without sacrificing the quality that makes them so valuable
    # perceptrons, networks, deep, iterative, likely, learning
  - 2.1 Neural Networks · p42 (pdf 44) · 748w · 1 fig
    > Generations of research into neural networks form the theoretical foundation for generative AI
    # internal, networks, hidden, representation, dimensionality, representations
    - 2.1.1 Linear Layers and Matmul · p44 (pdf 46) · 103w · 1 fig
      # vector, matrix, matmul, linear
    - 2.1.2 Activation Functions · p44 (pdf 46) · 218w · 2 fig
      # activation, relu, multi-layer, functions
  - 2.2 LLM Inference Mechanics · p46 (pdf 48) · 1788w · 2 fig
    > LLMs are autoregressive token generation models. An LLM generates new tokens one at a time based on every previous token
    # vocabulary, normalization, top-k, chat, logit, logits
    - 2.2.1 LLM Architecture · p49 (pdf 51) · 275w
      # name, causal, config.json, indicates
    - 2.2.2 Transformer Blocks · p50 (pdf 52) · 175w · 1 fig
      # blocks, sublayers, transformer, feed-forward

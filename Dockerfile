FROM nvidia/cuda:12.8.2-base-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq tar libgomp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /miner

ARG OZM_URL="https://github.com/OneZeroMiner/onezerominer/releases/download/v1.8.6/onezerominer-linux-1.8.6.tar.gz"
ARG OZM_SHA256="47ea652dcc7bacd49102203aab149dd6f678471e5fd69e68622363e0747c0f00"

RUN curl -fsSL "$OZM_URL" -o /tmp/ozm.tar.gz \
    && echo "${OZM_SHA256}  /tmp/ozm.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/ozm.tar.gz --strip-components=1 -C /miner \
    && rm -f /tmp/ozm.tar.gz \
    && chmod +x /miner/onezerominer \
    && /miner/onezerominer -V

COPY entrypoint.sh /miner/entrypoint.sh
RUN sed -i 's/\r$//' /miner/entrypoint.sh && chmod +x /miner/entrypoint.sh

ENTRYPOINT ["/miner/entrypoint.sh"]

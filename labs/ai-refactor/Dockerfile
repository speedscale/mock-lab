FROM golang@sha256:f20d83a83e18dbd2a4714b8ffd4b30b287b6243962dd75608e86abcc63ba4efc
ENV GOTOOLCHAIN=local CGO_ENABLED=0
COPY proxymock /usr/local/bin/proxymock
COPY source /opt/demo/source
RUN set -eu; for variant in original broken fixed; do \
      cd /opt/demo/source/$variant && go build -trimpath -o /opt/demo/bin/$variant .; \
    done
COPY workspace /work
COPY run-in-container.sh /opt/demo/run.sh
WORKDIR /work
ENTRYPOINT ["bash", "/opt/demo/run.sh"]

COPY verify.py /opt/demo/verify.py

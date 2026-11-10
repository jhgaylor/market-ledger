# makensis for release.sh (Homebrew's crashes on macOS here).
FROM docker.io/library/debian:13-slim
RUN apt-get update && apt-get install -y --no-install-recommends nsis && rm -rf /var/lib/apt/lists/*
WORKDIR /work
ENTRYPOINT ["makensis"]

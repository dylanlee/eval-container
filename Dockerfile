# == base ======================
FROM buildpack-deps:bookworm AS base
RUN apt update

# Rust envvars
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH \
    RUST_VERSION=1.81.0

# == node ======================
FROM base AS node
COPY nodesource.gpg /etc/apt/keyrings/nodesource.gpg
COPY <<EOF /etc/apt/sources.list.d/nodesource.list
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main
EOF
RUN --mount=type=cache,target=/var/cache/apt,id=framework-runtime-node \
    apt update \
    && apt install -y --no-install-recommends nodejs \
    && npm install --global yarn
RUN npm install --global svgo

# == R ===========================
FROM base AS r
COPY r-project.gpg /etc/apt/keyrings/r-project.gpg
COPY <<EOF /etc/apt/sources.list.d/r-project.list
deb [signed-by=/etc/apt/keyrings/r-project.gpg] https://cloud.r-project.org/bin/linux/debian bookworm-cran40/
deb-src [signed-by=/etc/apt/keyrings/r-project.gpg] https://cloud.r-project.org/bin/linux/debian bookworm-cran40/
EOF
RUN --mount=type=cache,target=/var/cache/apt,id=framework-runtime-r \
    apt update \
    && apt install -y --no-install-recommends \
      r-base-core \
      r-recommended

# == duckdb ======================
FROM base AS duckdb
RUN cd $(mktemp -d); \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) duckdbArch='amd64' ;; \
        arm64) duckdbArch='aarch64' ;; \
        *) echo >&2 "unsupported architecture: ${dpkgArch}"; exit 1 ;; \
    esac; \
    wget https://github.com/duckdb/duckdb/releases/download/v0.10.1/duckdb_cli-linux-${duckdbArch}.zip; \
    unzip duckdb_cli-linux-${duckdbArch}.zip; \
    install -m 0755 duckdb /usr/bin/duckdb;

# == python ========================
FROM base AS python

# Install Python
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      python3-setuptools \
      python3-wheel \
      python3-dev \
      python3-venv \
      libpython3-dev \
    && rm -rf /var/lib/apt/lists/*

# == rust ========================
FROM base AS rust

# Install Rust
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) rustArch='x86_64-unknown-linux-gnu'; rustupSha256='a3d541a5484c8fa2f1c21478a6f6c505a778d473c21d60a18a4df5185d320ef8' ;; \
        arm64) rustArch='aarch64-unknown-linux-gnu'; rustupSha256='76cd420cb8a82e540025c5f97bda3c65ceb0b0661d5843e6ef177479813b0367' ;; \
        *) echo >&2 "unsupported architecture: ${dpkgArch}"; exit 1 ;; \
    esac; \
    url="https://static.rust-lang.org/rustup/archive/1.27.0/${rustArch}/rustup-init"; \
    wget "$url"; \
    echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
    chmod +x rustup-init; \
    ./rustup-init -y --no-modify-path --profile minimal --default-toolchain $RUST_VERSION --default-host ${rustArch}; \
    rm rustup-init; \
    chmod -R a+w $RUSTUP_HOME $CARGO_HOME;

# Install cargo-binstall
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "${dpkgArch##*-}" in \
        amd64) binstallArch='x86_64-unknown-linux-gnu' ;; \
        arm64) binstallArch='aarch64-unknown-linux-gnu' ;; \
        *) echo >&2 "unsupported architecture: ${dpkgArch}"; exit 1 ;; \
    esac; \
    url="https://github.com/cargo-bins/cargo-binstall/releases/download/v1.6.4/cargo-binstall-${binstallArch}.tgz"; \
    curl -L --proto '=https' --tlsv1.2 -sSf "$url" | tar -xvzf -; \
    ./cargo-binstall -y --force cargo-binstall

# Install rust-script and apache arrow-tools
RUN cargo binstall -y --force rust-script csv2arrow csv2parquet json2arrow json2parquet

# == general-cli =================
FROM base AS general-cli
RUN --mount=type=cache,target=/var/cache/apt,id=framework-runtime-general-cli \
    set -eux; \
    apt update; \
    apt install -y --no-install-recommends \
        bind9-dnsutils \
        csvkit \
        iputils-ping \
        iputils-tracepath \
        jq \
        nano \
        netcat-openbsd \
        openssl \
        optipng \
        ripgrep \
        silversearcher-ag \
        vim \
        zstd

# == runtime =====================
FROM base AS runtime
COPY --from=general-cli / /
COPY --from=node / /
COPY --from=r / /
COPY --from=duckdb / /
COPY --from=python / /
COPY --from=rust / /

# Create mounting directories
RUN mkdir -p /viz-metrics /static-cat

# Clone stac-browser
RUN git clone https://github.com/radiantearth/stac-browser.git /stac-browser

# Build stac-browser
RUN cd /stac-browser && \
    npm install && \
    npm run build

# Install http-server
RUN npm install --global http-server

# make sure that cargo bin can be seen from non interactive shell
RUN echo 'export PATH=/usr/local/cargo/bin:$PATH' >> /root/.bashrc

# Create alias for running servers
RUN echo 'alias eval-servers="cd /viz-metrics && npm run dev -- --host 0.0.0.0 & python3 -m http.server 8000 --bind 0.0.0.0 --directory /static-cat & cd /stac-browser/dist && http-server -p 8080 --host 0.0.0.0 --cors & wait"' >> /root/.bashrc

# Make sure the alias is available in non-interactive shells
RUN echo 'shopt -s expand_aliases' >> /root/.bashrc
RUN echo 'source /root/.bashrc' >> /root/.profile

# Set the default command to use a login shell, which will load .profile
CMD ["/bin/bash", "-l"]

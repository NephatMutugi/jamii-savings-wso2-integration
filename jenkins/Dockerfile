# Jenkins with the toolchain this project's pipeline needs.
# Deliberately no Docker CLI and no mounted Docker socket: MI is deployed by
# dropping a CAR into a bind-mounted directory and APIM over HTTPS, so the
# pipeline needs network access, not control of the host's Docker daemon.
FROM jenkins/jenkins:lts-jdk21

USER root

ARG MAVEN_VERSION=3.9.9
# Must match the APIM version, or imports fail with confusing errors.
ARG APICTL_VERSION=4.6.0

# libxml2-utils provides xmllint, which the Validate stage uses to reject
# malformed Synapse artifacts before Maven or MI ever see them.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq unzip ca-certificates libxml2-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -sSL -o /tmp/maven.tar.gz \
      "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
 && tar -xzf /tmp/maven.tar.gz -C /opt \
 && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn \
 && rm /tmp/maven.tar.gz

RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
      amd64) APICTL_ARCH=amd64 ;; \
      arm64) APICTL_ARCH=arm64 ;; \
      *) echo "unsupported architecture: $ARCH" && exit 1 ;; \
    esac \
 && curl -sSL -o /tmp/apictl.tar.gz \
      "https://github.com/wso2/product-apim-tooling/releases/download/v${APICTL_VERSION}/apictl-${APICTL_VERSION}-linux-${APICTL_ARCH}.tar.gz" \
 && tar -xzf /tmp/apictl.tar.gz -C /opt \
 && ln -s /opt/apictl/apictl /usr/local/bin/apictl \
 && rm /tmp/apictl.tar.gz

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g newman \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/*

USER jenkins

# Pre-install the plugins the pipeline needs. Fetching them through the setup
# wizard proved unreliable (Pipeline and Git both failed to download on a
# first run), and a CI image that only works when the plugin site cooperates
# is not reproducible for anyone else.
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --latest true

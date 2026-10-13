# Built by the Jenkins pipeline (phase 5). Local dev uses docker-compose.yml,
# which bind-mounts the same artifacts into the stock image instead, so
# every edit doesn't require a rebuild.
#
# Build context is mi/ (see jenkins/Jenkinsfile): `docker build -f
# deployment/docker/Dockerfile .` from inside mi/.
#
# VERIFY: the exact carbon-home path and CAR auto-deploy directory below for
# the pinned wso2/wso2mi:4.6.0 image.
FROM wso2/wso2mi:4.6.0

# Note the underscore: vscode-car-plugin names the CAR
# {artifactId}_{version}.car, not Maven's usual {artifactId}-{version}.
ARG CAR_FILE=target/jamii-mi_1.0.0.car

COPY ${CAR_FILE} /home/wso2carbon/wso2mi-4.6.0/repository/deployment/server/carbonapps/
COPY deployment/deployment.toml /home/wso2carbon/wso2mi-4.6.0/conf/deployment.toml
COPY deployment/libs/mysql-connector-j.jar /home/wso2carbon/wso2mi-4.6.0/lib/mysql-connector-j.jar

USER wso2carbon

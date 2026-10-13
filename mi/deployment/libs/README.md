# JDBC driver

This directory is gitignored except this file. Before the first
`docker compose up` (or Jenkins build), download the MySQL Connector/J jar
here so the bind mount in `docker-compose.yml` and the `COPY` in
`deployment/docker/Dockerfile` have something to mount/copy:

```bash
curl -sSL -o mi/deployment/libs/mysql-connector-j.jar \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/9.1.0/mysql-connector-j-9.1.0.jar
```

# Shallow QC

Tool to extract QC information from a shallow molecular pipeline run.
Output files:

- `shallow-qc.json`: JSON file containing QC information

## Prerequisites

- [JDK 21](https://www.oracle.com/java/technologies/downloads/#java21)
- [Maven 3.x](https://maven.apache.org/install.html)

Both can also be installed with [SDKMAN!](https://sdkman.io/). 

## Local development

In IntelliJ, right-click the [pom.xml](pom.xml) file and select "Add as Maven Project".

### Build code

Build the code with Maven 3.x:

    mvn clean verify

### Build Docker image

Build the Docker image with

    docker build -t shallow-qc --platform linux/amd64 .

Run it for pipeline output in `~/data/pipeline-output` with:

    docker run \
      --platform linux/amd64 \
      -v ~/data:/data \
      -w /data/result \
      shallow-qc \
      --pipeline-output-dir /data/pipeline-output

In this example the output files will be written to the directory `~/data/result`.

### Release

Create a git tag like `shallow-qc-0.0.1` (so "shallow-qc-" followed by a semantic version).
Alpha and beta releases are also suppored (e.g. `shallow-qc-0.0.1-alpha.1`).
Push the tag to start a build.

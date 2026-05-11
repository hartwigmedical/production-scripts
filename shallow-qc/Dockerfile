FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
COPY src/ src/
RUN mvn verify

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/shallow-qc-jar-with-dependencies.jar .
ENTRYPOINT ["java", "-jar", "/app/shallow-qc-jar-with-dependencies.jar"]
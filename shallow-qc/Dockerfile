FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml src/ ./
RUN mvn package -DskipTests -q

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/shallow-qc.jar .
ENTRYPOINT ["java", "-jar", "/app/shallow-qc.jar"]
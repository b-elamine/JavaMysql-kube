FROM techiescamp/jre-17:1.0.0
COPY /target/*.jar /app/java.jar
EXPOSE 8080

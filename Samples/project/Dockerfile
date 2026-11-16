# Build stage
FROM swift:6.0 AS build
WORKDIR /app
COPY . .
RUN swift build -c release

FROM ubuntu:24.04
ENV PORT=8080
COPY --from=build /app/.build/release/app /usr/local/bin/app
EXPOSE $PORT
CMD ["app", "--port", "8080"]

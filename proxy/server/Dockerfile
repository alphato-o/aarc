# AARC proxy — standalone Node build of the Cloudflare Worker.
# Build context is the proxy/ directory (see docker-compose.yml):
#   docker build -f server/Dockerfile .
FROM node:20-alpine AS build
WORKDIR /app
# Worker source + its runtime dep (zod)
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY src ./src
# Server adapter + bundler
COPY server/package.json server/package-lock.json* ./server/
RUN cd server && npm install
COPY server/build.mjs server/server.mjs ./server/
RUN cd server && npm run build

FROM node:20-alpine
WORKDIR /app/server
COPY --from=build /app/server/dist ./dist
COPY --from=build /app/server/server.mjs ./
ENV PORT=8787
EXPOSE 8787
CMD ["node", "server.mjs"]

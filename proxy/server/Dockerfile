# AARC proxy — standalone Node build of the Cloudflare Worker.
# Build context is the proxy/ directory (see docker-compose.yml):
#   docker build -f server/Dockerfile .
#
# Node 24, not 20: the live-asr relay dials VOLC with the global `WebSocket`
# client, which Node only ships unflagged from 22.4. On node:20-alpine the
# gateway boots fine and then throws "WebSocket is not defined" the first time
# the runner speaks, which is the worst possible place to find out.
FROM node:24-alpine AS build
WORKDIR /app
# Worker source + its runtime dep (zod)
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY src ./src
# Server adapter + bundler
COPY server/package.json server/package-lock.json* ./server/
RUN cd server && npm install
COPY server/build.mjs server/server.mjs server/wsServer.mjs server/liveAsr.mjs ./server/
RUN cd server && npm run build

FROM node:24-alpine
WORKDIR /app/server
COPY --from=build /app/server/dist ./dist
COPY --from=build /app/server/server.mjs /app/server/wsServer.mjs /app/server/liveAsr.mjs ./
ENV PORT=8787
EXPOSE 8787
CMD ["node", "server.mjs"]

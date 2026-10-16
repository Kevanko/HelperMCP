FROM node:22-alpine
WORKDIR /app
COPY relay/package*.json relay/
RUN cd relay && npm ci --omit=dev
COPY relay/server.js relay/landing.html relay/cli.mjs relay/hints.json relay/
COPY agent agent
COPY recipes recipes
ENV PORT=8444
EXPOSE 8444
USER node
CMD ["node", "relay/server.js"]

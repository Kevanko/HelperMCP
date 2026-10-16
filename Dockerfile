FROM node:22-alpine
WORKDIR /app
COPY relay/package*.json relay/
RUN cd relay && npm ci --omit=dev
COPY relay/server.js relay/landing.html relay/cli.mjs relay/report.mjs relay/admin.mjs relay/admin.js relay/admin.css relay/hints.json relay/panels.js relay/panels.css relay/
COPY agent agent
COPY recipes recipes
ENV PORT=8444
EXPOSE 8444
USER node
CMD ["node", "relay/server.js"]

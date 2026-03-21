FROM node:18-alpine AS deps
WORKDIR /app

COPY package.json ./
RUN npm install

FROM node:18-alpine AS build
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY tsconfig.json tsconfig.build.json nest-cli.json ./
COPY src ./src

RUN npm run build && npm prune --omit=dev

FROM node:18-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000

RUN addgroup -S nestjs && adduser -S nestjs -G nestjs

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json

USER nestjs

EXPOSE 3000

CMD ["node", "dist/main.js"]

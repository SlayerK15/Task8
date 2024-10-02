FROM node:18-alpine

WORKDIR /usr/src/app

COPY package*.json ./

RUN node --max-old-space-size=1024 $(which npm) install -g @medusajs/medusa

RUN node --max-old-space-size=1024 $(which npm) install

COPY . .

EXPOSE 9000

CMD ["sh", "-c", "medusa migrations run && medusa start"]

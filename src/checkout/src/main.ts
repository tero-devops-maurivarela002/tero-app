import { ConsoleLogger, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';

async function bootstrap() {
  // Los logs propios de Nest (arranque, errores) también en JSON (DEVOPS-48).
  const app = await NestFactory.create(AppModule, {
    logger: new ConsoleLogger({ json: true }),
  });
  app.useGlobalPipes(new ValidationPipe());
  app.enableShutdownHooks();

  const port = process.env.PORT || 8080;
  await app.listen(port);
}
bootstrap();

import { Injectable, NestMiddleware } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';
import { requestLogger } from '../jsonlog';

// Una línea JSON por request (DEVOPS-48), mismo formato que el resto de los servicios.
@Injectable()
export class LoggerMiddleware implements NestMiddleware {
  private readonly log = requestLogger('checkout');

  use(request: Request, response: Response, next: NextFunction) {
    this.log(request, response, next);
  }
}

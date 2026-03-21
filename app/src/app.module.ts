import { Module } from '@nestjs/common';
import { TerminusModule } from '@nestjs/terminus';
import { HealthModule } from './health/health.module';

@Module({
  imports: [TerminusModule, HealthModule],
})
export class AppModule {}

import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { Type } from 'typebox';
import registerWorkflow from './extension.mjs';

export default function fenrirWorkflow(pi: ExtensionAPI): void {
  registerWorkflow(pi, Type);
}

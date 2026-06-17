import { AgentforceConversationClient as SFClient } from '@salesforce/agentforce-conversation-client';

interface Props {
  agentId: string;
}

export function AgentforceConversationClient({ agentId }: Props) {
  if (!agentId || agentId.startsWith('<')) return null;
  return <SFClient agentId={agentId} />;
}

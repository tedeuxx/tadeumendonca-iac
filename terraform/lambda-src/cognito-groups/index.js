// Cognito trigger — group assignment for federated (Google) users (/infrastructure/cognito).
// IMPORTANT: PostAuthentication does NOT fire for federated/hosted-UI sign-in — only PreTokenGeneration
// does. So we do EVERYTHING in this handler regardless of trigger: ensure real Cognito membership
// (AdminAddUserToGroup) AND override the token's group claim (so the FIRST token already carries it,
// before membership propagates). The override groups are the UNION of the email allowlist + the user's
// existing real membership — so a manually-granted group survives the override.
//
// FAIL-OPEN: every path is wrapped; any error returns the event UNCHANGED — a trigger that throws would
// block login/token issuance, so we never throw. The SDK is lazy-required inside try/catch too.
'use strict';

const MANAGED = ['registered', 'admin'];
const ADMIN_EMAILS = (process.env.ADMIN_EMAILS || '')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

exports.handler = async (event) => {
  const desired = new Set(['registered']);
  try {
    const email = (event.request?.userAttributes?.email || '').toLowerCase();
    if (email && ADMIN_EMAILS.includes(email)) desired.add('admin');

    const sdk = require('@aws-sdk/client-cognito-identity-provider');
    const client = new sdk.CognitoIdentityProviderClient({});

    // Union with existing real membership so a manually/previously granted group survives the override.
    try {
      const res = await client.send(
        new sdk.AdminListGroupsForUserCommand({ UserPoolId: event.userPoolId, Username: event.userName }),
      );
      for (const g of res.Groups || []) if (MANAGED.includes(g.GroupName)) desired.add(g.GroupName);
    } catch (e) {
      console.error('AdminListGroupsForUser failed (continuing):', e);
    }

    // Sync real Cognito group membership (idempotent, best-effort).
    await Promise.allSettled(
      [...desired].map((GroupName) =>
        client.send(new sdk.AdminAddUserToGroupCommand({ UserPoolId: event.userPoolId, Username: event.userName, GroupName })),
      ),
    );

    console.log(JSON.stringify({ msg: 'cognito-groups', triggerSource: event.triggerSource, email, groups: [...desired], userName: event.userName }));
  } catch (err) {
    console.error('cognito-groups trigger error (fail-open, auth proceeds):', err);
  }

  // For token generation, override the group claim so it lands in the token immediately (first login too).
  if (typeof event.triggerSource === 'string' && event.triggerSource.startsWith('TokenGeneration')) {
    event.response = event.response || {};
    event.response.claimsOverrideDetails = {
      ...(event.response.claimsOverrideDetails || {}),
      groupOverrideDetails: { groupsToOverride: [...desired] },
    };
  }
  return event;
};

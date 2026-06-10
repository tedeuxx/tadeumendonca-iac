// Cognito trigger — group assignment for federated (Google) users (/infrastructure/cognito).
// PostAuthentication does NOT fire for federated/hosted-UI sign-in — only PreTokenGeneration does, so
// everything happens here regardless of trigger.
//
// SAFETY (a pre-token trigger that errors OR times out blocks token issuance = breaks login):
//   1. Compute groups from the email allowlist (pure, instant) and set the TOKEN override FIRST — this
//      is the authoritative path for the API GW authorizer / BFF and needs no SDK/IAM, so it's
//      guaranteed even if the calls below are slow.
//   2. Sync real Cognito membership (admin-console visibility) only as BEST-EFFORT, hard-capped well
//      under the Lambda timeout via Promise.race, fail-open. It can never delay/break login.
'use strict';

const ADMIN_EMAILS = (process.env.ADMIN_EMAILS || '')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

const cap = (p, ms) => Promise.race([p, new Promise((r) => setTimeout(r, ms))]);

exports.handler = async (event) => {
  const email = (event.request?.userAttributes?.email || '').toLowerCase();
  const groups = ['registered'];
  if (email && ADMIN_EMAILS.includes(email)) groups.push('admin');

  // 1) Token override FIRST — instant, no I/O. Authoritative for authz.
  if (typeof event.triggerSource === 'string' && event.triggerSource.startsWith('TokenGeneration')) {
    event.response = event.response || {};
    event.response.claimsOverrideDetails = {
      ...(event.response.claimsOverrideDetails || {}),
      groupOverrideDetails: { groupsToOverride: groups },
    };
  }

  // 2) Best-effort real membership — capped at 3s so it can never delay/break the response.
  try {
    const sdk = require('@aws-sdk/client-cognito-identity-provider');
    const client = new sdk.CognitoIdentityProviderClient({});
    await cap(
      Promise.allSettled(
        groups.map((GroupName) =>
          client.send(new sdk.AdminAddUserToGroupCommand({ UserPoolId: event.userPoolId, Username: event.userName, GroupName })),
        ),
      ),
      3000,
    );
    console.log(JSON.stringify({ msg: 'cognito-groups', triggerSource: event.triggerSource, email, groups, userName: event.userName }));
  } catch (err) {
    console.error('cognito-groups membership sync failed (fail-open):', err);
  }
  return event;
};

// Cognito trigger — group assignment for federated (Google) users (/infrastructure/cognito).
// Two triggers, one handler (dispatch on event.triggerSource):
//   - pre-token-generation: inject cognito:groups into the issued token (works on the FIRST login too).
//     This is the authoritative path for the API GW authorizer / BFF — needs NO SDK/IAM.
//   - post-authentication: best-effort sync of real Cognito group membership (AdminAddUserToGroup).
//
// FAIL-OPEN by design: every path is wrapped so any error returns the event UNCHANGED — a trigger that
// throws would block login/token issuance, so we never throw. Worst case a group isn't assigned that
// round (caught in testing), but auth always proceeds. The SDK is lazy-required inside try/catch so a
// missing module can't break login either.
'use strict';

const ADMIN_EMAILS = (process.env.ADMIN_EMAILS || '')
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

const groupsFor = (email) => {
  const g = ['registered'];
  if (email && ADMIN_EMAILS.includes(email.toLowerCase())) g.push('admin');
  return g;
};

exports.handler = async (event) => {
  try {
    const email = event.request?.userAttributes?.email || '';
    const groups = groupsFor(email);

    if (typeof event.triggerSource === 'string' && event.triggerSource.startsWith('TokenGeneration')) {
      // Override the group claim in the token (id + access) — authoritative for the BFF.
      event.response = event.response || {};
      event.response.claimsOverrideDetails = {
        ...(event.response.claimsOverrideDetails || {}),
        groupOverrideDetails: { groupsToOverride: groups },
      };
      return event;
    }

    // post-authentication (and others): keep real Cognito group membership in sync (best-effort).
    const { CognitoIdentityProviderClient, AdminAddUserToGroupCommand } = require('@aws-sdk/client-cognito-identity-provider');
    const client = new CognitoIdentityProviderClient({});
    await Promise.allSettled(
      groups.map((GroupName) =>
        client.send(
          new AdminAddUserToGroupCommand({ UserPoolId: event.userPoolId, Username: event.userName, GroupName }),
        ),
      ),
    );
  } catch (err) {
    console.error('cognito-groups trigger error (fail-open, auth proceeds):', err);
  }
  return event;
};

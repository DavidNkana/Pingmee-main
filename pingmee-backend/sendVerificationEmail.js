const admin = require("firebase-admin");
const fetch = (...args) => import('node-fetch').then(({default: fetch}) => fetch(...args));


const RESEND_API_KEY = process.env.RESEND_API_KEY || 're_KWY1HkFm_9gG72DBKWgQBC3itzGNt44HJ';
const SENDER_EMAIL = 'pingmee.pingoo@gmail.com';

async function sendCustomVerificationEmail(toEmail) {
  // Ensure the user exists
  let user;
  try {
    user = await admin.auth().getUserByEmail(toEmail);
  } catch {
    user = await admin.auth().createUser({
      email: toEmail,
      password: "TempPassword123!",
    });
  }

  const link = await admin.auth().generateEmailVerificationLink(toEmail, {
    url: "https://pingmee-welcome.netlify.app",
    handleCodeInApp: true,
  });

  const html = `
    <div style="font-family: Poppins, sans-serif; text-align: center; padding: 30px;">
      <img src="https://yourdomain.com/pingoo.png" alt="Pingoo" width="80" />
      <h2 style="color: #1DB954;">Welcome to PingMee!</h2>
      <p style="font-size: 16px;">Click the button below to verify your email and start making real connections.</p>
      <a href="${link}" style="display: inline-block; margin-top: 20px; background-color: #1DB954; color: white; padding: 12px 20px; text-decoration: none; border-radius: 8px;">Verify Email</a>
    </div>
  `;

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: `PingMee <${SENDER_EMAIL}>`,
      to: toEmail,
      subject: "Verify your email address",
      html,
    }),
  });

  const result = await response.json();

  if (!response.ok) {
    throw new Error(`Resend email failed: ${JSON.stringify(result)}`);
  }

  console.log(`✅ Verification email sent to ${toEmail}`);
}

module.exports = { sendCustomVerificationEmail };

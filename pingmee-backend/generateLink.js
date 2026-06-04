const express = require('express');
const admin = require("firebase-admin");
const fetch = require("node-fetch");
const cors = require("cors");

const app = express();
app.use(cors());
app.use(express.json()); // for parsing application/json

admin.initializeApp({
  credential: admin.credential.cert(require("./serviceAccountKey.json")),
});

const RESEND_API_KEY = 're_KWY1HkFm_9gG72DBKWgQBC3itzGNt44HJ';
const SENDER_EMAIL = 'pingmee.pingoo@gmail.com';

app.post('/send-verification', async (req, res) => {
  const { email } = req.body;

  if (!email) return res.status(400).send({ error: "Email is required" });

  try {
    // Confirm or create user
    let user;
    try {
      user = await admin.auth().getUserByEmail(email);
    } catch {
      user = await admin.auth().createUser({
        email: email,
        password: 'TempPassword123!',
      });
    }

    const link = await admin.auth().generateEmailVerificationLink(email, {
      url: 'https://pingmee-welcome.netlify.app',
      handleCodeInApp: true,
    });

    const html = `
      <div style="font-family: Poppins, sans-serif; text-align: center; padding: 30px;">
        <img src="https://yourdomain.com/pingoo.png" alt="Pingoo" width="80" />
        <h2 style="color: #1DB954;">Welcome to PingMee!</h2>
        <p>Click the button below to verify your email and start connecting.</p>
        <a href="${link}" style="background:#1DB954; color:#fff; padding:12px 20px; border-radius:8px; text-decoration:none;">Verify Email</a>
      </div>
    `;

    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: `PingMee <${SENDER_EMAIL}>`,
        to: email,
        subject: "Verify your email address",
        html,
      }),
    });

    const result = await response.json();

    if (!response.ok) {
      return res.status(500).send({ error: "Email send failed", detail: result });
    }

    return res.send({ success: true });
  } catch (err) {
    return res.status(500).send({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`✅ PingMee server running on port ${PORT}`));

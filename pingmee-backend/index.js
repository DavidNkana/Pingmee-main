const express = require("express");
const cors = require("cors");
const bodyParser = require("body-parser");
const admin = require("firebase-admin");

const { sendCustomVerificationEmail } = require("./sendVerificationEmail");

const app = express();
app.use(cors());
app.use(bodyParser.json());

// Load service account from environment variable (set in Render)
const serviceAccount = {
  "type": "service_account",
  "project_id": "pingmee-first-step-auth",
  "private_key_id": "466f4970b04cb47ebd13ca1056152aadb1296101",
  "private_key": `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCq6UMTWh5AcW5v
vXjok861na5+5+h+W1WfkpN4Pwzux4qMnT9c1oHHqlv0aH6ITXW1v0r4yywf6Tli
KHSgOJ3Epvq/CyDpQGCz5+v22qsNsFRGP7z/lIX2EQqgOhdqAheDLK9hY/ovpiGE
fHkUAQ7Sc42GS20gsqpvIil4iPIGLTLqGut+qq5oZaYWq4uLW8gJTbWo2K9S6TSP
vnBmO5rdRuvvzOZRND5jEIlhJROBF+QRQ3kPpSYSA24Q3a/lW/L/IqfOYH5VpE7K
lz+S/B+94JedP3bhZnv9HTrOKMJq63WwtQFSALvfFeEIAO6p6i/GRuMq8tisF3h8
96Sg9umFAgMBAAECggEAOZs05g1ue+cfw5735WCIgFOdEJ5HEWvkkMv9U77gs4zj
SKDpzfdpN+zWYKtl1rhREAjhkrkcbscT9d9P6/8ZQkLL6l+sYKI31fu6X3J1zD/e
L+1k3Tpo6rb0v2vFH5CD70088dUaazwSOQ8hWlo+7jVPgu/iYO6HnrzDgKKb/PNr
H0q4HsZV7mE8y9VN302xPHKyz0CYBzo49rwrxIiOo/VWR6tzRFWV4aJPaRAI3Qx1
CoS3qKyxxvpZ/Bp2guU8bynSmRI+LhR55Rvwyh/xdbq2IjCupFlyNe8x02Om6sIw
tkQp9gurzh65n1dChXAUMyw2oHeTUThGPccRYpZskwKBgQDR5yYemUcp9deLKybE
4L5vh6adKgi46go3bPgp7IXdcLVRyUjlsvWVTseBY7KkcaanDk+N88Msd3chkCuT
ZYrGw7z3h6xfb7liwtl9O4kAhB/OeBoAskTcHNh0TjxmWs9jUeNd0lFDGdBfM35d
0B06C9ldr6scRFn81HnKeQwbiwKBgQDQcfob+Cb2GbXQReVgJaInoJdEgwO6cvlU
Mcxh/d0hMgshNI8g+NDy2oizrJV5hMSRzeftYy/jzuUhcA3ij4X9Xcv9RrMcCaJC
BW/YlJ7kuh55e2JCuMl7Zn79pWFALijEoWOIXbFW3+LDo4MeL04BE7NXzPJ0EtGx
8QNqf3DxLwKBgQDA125MGmIpCLXYI/LgWeJbsPK/3YhZ6pssRK7SRXzO7ueGljik
33+EhvX/x8quDcQgIqOwNM2RIsiOS1fdeSLAbcBEYZ9ZptlZBM6voWzCzqAyHmE1
VpKw7sdmQyJ2nuN9yhPrdHg3/5VSgYqNQdA4Lf6rdeLse1d5UvP5srAO9QKBgDw2
8L1rrjWhr7f+uQhRVsqDxa7w+f6+f/Amgpg8MckJH9XzzPUFa7b8Ekl1LajxBafp
B3q4EHmKpv5F1H0CYP6UPf1okw0ia1EPKQQzysLgUTVewz/rCakwLrcvMyzLKNPE
m3AlQLmL64IAljv+BlahTkmq1s9ZMGJq8UWukv3ZAoGAIhWMCdqvjLWZdjzDNLQp
uWBckNZE5BzSxuAzQzE0siES69UeP3gByjGtAEsVAb9FM+ifq02cfRg+HeNLN9Ci
J8QLTBX5kG8B2y2JVCXyeo7KfvvdS7KUXZOioc2wBC1jt0sk8J4bhECGhgs8CRk9
/L8Z0HHlmiT6TDPdhBJ7yoY=
-----END PRIVATE KEY-----`
  ,
  "client_email": "firebase-adminsdk-fbsvc@pingmee-first-step-auth.iam.gserviceaccount.com",
  "client_id": "117888264770990165464",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/firebase-adminsdk-fbsvc%40pingmee-first-step-auth.iam.gserviceaccount.com",
  "universe_domain": "googleapis.com"
};


admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

app.get('/', (req, res) => {
  res.send('PingMee backend is running. Use POST /send-verification to send emails.');
});


// Route to send verification email
app.post("/send-verification", async (req, res) => {
  const { email } = req.body;

  if (!email) {
    return res.status(400).json({ error: "Email is required" });
  }

  try {
    await sendCustomVerificationEmail(email);
    res.status(200).json({ success: true, message: "Email sent" });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Start server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`✅ Server is running on port ${PORT}`);
});

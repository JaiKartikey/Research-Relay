# Research-Relay (EC2 start/stop edition)

Give it a topic → a relay of AI agents researches it, writes a full report, safety-checks it, caches it and remembers it.

**Why the name?** It works like a relay race. The Search agent hands the baton to the Summarize agent, then the Writer, then the Critic. Bedrock Guardrails act as the referee at the start and the finish line.

**What's special about this edition:** it's the **cheapest** way to run Research-Relay on AWS. Everything runs on **one small EC2 instance** with Docker Compose. You **Start** it before a demo and **Stop** it after. While it's stopped you only pay for the disk, about **$2–3 per month**.

The app code is exactly the same as `Research-Relay-AWS`. Only the "where it runs" part changed.

---

## How it works (the 30-second version)

```
           Internet
              │  only port 80 is open
              ▼
┌──────────── EC2 t4g.small (Sydney) ────────────┐
│  docker compose                                 │
│   app (FastAPI + worker) ──► tensorzero ──► Gemini (Groq if Gemini fails)
│        │        │                               │
│      redis   postgres+pgvector (data on disk)   │
└────────────────────────────────────────────────┘
      │ instance IAM role (no access keys)
      ├──► Secrets Manager  research-relay/config
      └──► Bedrock Guardrail (input + output check)
```

- **On every boot** the instance runs a small script (it's inside `terraform/main.tf`) that:
  1. downloads the latest code zip from S3,
  2. reads the secret and writes a `.env` file (keys for TensorZero and Postgres),
  3. runs `docker compose up -d --build`.
- So "Start instance" in the AWS console = the app comes up by itself. Nothing to type.
- Postgres and Redis data live on the EC2 disk (EBS). **Stop/Start keeps your data.** Only `terraform destroy` deletes it.

---

## What It Uses

| Component | What It Does |
|---|---|
| **FastAPI** | REST API: receives topics, returns reports |
| **LangGraph** | 4-agent relay: Search → Summarize → Write → Verify (Critic) |
| **TensorZero** | LLM gateway: sends every call to **Google Gemini 2.5 Flash**, falls back to **Groq Llama 3.1** if Gemini fails |
| **AWS Bedrock Guardrails** | Blocks harmful input and output |
| **Redis** (container) | Semantic cache + session memory + job queue |
| **PostgreSQL + pgvector** (container) | Long-term memory: stores reports as vectors |
| **AWS Secrets Manager** | Holds all settings and keys; the app reads it at startup |
| **EC2 + Docker Compose** | Runs the 4 containers on one machine |
| **LangSmith** (optional) | Traces every agent run + LLM-as-judge scores |
| **Terraform** | Creates all AWS infrastructure |

---

## File Structure

```
Research-Relay-EC2/
├── app/                      The API (unchanged, one class per agent)
│   ├── main.py               API, background worker, all endpoints
│   ├── agents.py             SearchAgent, SummarizeAgent, WriterAgent, CriticAgent, OrchestratorAgent
│   ├── cache.py              Redis semantic cache
│   ├── guardrails.py         Bedrock safety checks
│   ├── memory.py             Session memory (Redis) + long-term memory (pgvector)
│   ├── queue.py              Redis Streams job queue
│   ├── output.py             PDF export, JSON report, report diff
│   ├── eval.py               LLM-as-judge evaluation
│   ├── config.py             Loads everything from AWS Secrets Manager (research-relay/config)
│   ├── auth.py               API key check
│   ├── retry.py              Exponential backoff for LLM calls
│   ├── pool.py               PostgreSQL connection pool
│   └── Dockerfile
├── tensorzero/               Gemini first, Groq fallback (+ prompt templates)
├── docker-compose.yml        NEW: app + tensorzero + redis + postgres on one machine
├── terraform/main.tf         NEW: VPC, EC2, security group, IAM role, guardrail, secret, code bucket
├── pyrit_dashboard/          Red team dashboard (kept, but NOT started on EC2, see the end)
├── tests/                    22 unit tests (no AWS needed, they use fakes)
├── bootstrap.sh / .bat       One-time: creates the S3 bucket for terraform state
├── requirements.txt          App packages
├── requirements-dev.txt      Test packages
├── index.html                Frontend
└── ARCHITECTURE.mmd          Diagram (paste into mermaid.live)
```

---

## What it costs (Sydney, approximate)

| When | What you pay for | About |
|---|---|---|
| **Stopped** (most of the time) | 20 GB disk ($1.9) + secret ($0.40) + tiny S3 zip | **~$2.5 / month** |
| **Running** (during a demo) | t4g.small + its public IP | **~$0.03 / hour** |
| Per request | Bedrock Guardrail checks | a fraction of a cent |

Example: stopped all month + 20 hours of demos ≈ **$3 / month** → about **$18 for 6 months**. Well inside a $100 budget.

> **The one way to burn money:** forgetting to Stop it. A running instance left on for a whole month is ~$20. That's why step 0 below is a budget alarm.

Gemini and Groq keys are free tier, so no LLM bill.

---

## What you need

| Thing | Where |
|---|---|
| AWS account | You already have one |
| **Gemini API key** (free) | https://aistudio.google.com/apikey |
| **Groq API key** (free) | https://console.groq.com/keys |
| LangSmith key (optional) | https://smith.langchain.com → Settings → API Keys |

You don't install anything on your laptop. Terraform runs in **AWS CloudShell** (a terminal inside the AWS console, already logged in).

**AWS services used:** EC2, VPC, IAM, S3, Secrets Manager, Bedrock Guardrails, Systems Manager (for the console terminal). If your AWS Organization blocks one of these, `terraform apply` stops with an "explicit deny" error that names it. Send me that error.

> **Region:** everything is in **Asia Pacific (Sydney) `ap-southeast-2`**. Keep the console on Sydney (top right).

> **Only one Research-Relay at a time:** this edition and `Research-Relay-AWS` (ECS) both use the secret name `research-relay/config`. If the ECS one is deployed, run `terraform destroy` there first.

---

## Setup: follow in order (one time)

### 0. Set a budget alarm FIRST (2 minutes, free)

AWS console → search **Budgets** → **Create budget** → **Use a template** → **Monthly cost budget**.

- Budget name: `research-relay`
- Budgeted amount: `10` (USD)
- Email: your email

Create. AWS now emails you when you hit 85% and 100% of $10 in a month. If you get that email, you probably forgot to Stop the instance.

### 1. Open AWS CloudShell and get the code

AWS console → region **Sydney** → click the `>_` icon (CloudShell) in the top bar.

Get the `Research-Relay-EC2` folder into CloudShell, either way works:

- **From GitHub:** `git clone https://github.com/JaiKartikey/Research-Relay.git && cd Research-Relay` (if the repo is private, GitHub asks for your username and a personal access token as the password)
- **Or upload it:** on Windows, right-click the `Research-Relay-EC2` folder → **Send to → Compressed (zipped) folder**. In CloudShell click **Actions → Upload file**, pick the zip, then:
  ```bash
  unzip -o Research-Relay-EC2.zip && cd Research-Relay-EC2
  ```

Install terraform in CloudShell (once):

```bash
curl -sLo tf.zip https://releases.hashicorp.com/terraform/1.10.5/terraform_1.10.5_linux_amd64.zip
unzip -o tf.zip -d ~/bin && rm tf.zip
terraform version
```

### 2. Create the terraform state bucket (one time only)

Terraform remembers what it created in a "state file". We keep it in S3 so it's never lost. (If you already ran this for the ECS edition, it just says "already exists". That's fine, both editions share the bucket but use different files inside it.)

```bash
bash bootstrap.sh
```

### 3. Create everything

```bash
cd terraform
chmod +x tf.sh     # one time only
./tf.sh apply
```

> **Always use `./tf.sh` instead of `terraform`** (for example `./tf.sh apply`, `./tf.sh output -raw api_key`, `./tf.sh destroy`). It finds your state bucket by itself and does the CloudShell setup (`TF_DATA_DIR`, `terraform init`) whenever CloudShell has wiped it, so you never type those again. Your state is always safe in S3.

Type `yes`. Terraform takes ~2 minutes. At the end it prints something like:

```
app_url            = "http://13.211.xx.xx"
instance_id        = "i-0abc123..."
config_secret_name = "research-relay/config"
```

**The very first boot is slow (~10–15 minutes).** The instance installs Docker and builds the images (PyTorch for the embedding model is big). Later Starts take 1–2 minutes because Docker remembers the build.

### 4. Add your LLM keys to Secrets Manager

AWS console → **Secrets Manager** → `research-relay/config` → **Retrieve secret value** → **Edit**.

| Key | Value |
|---|---|
| `GEMINI_API_KEY` | your Gemini key |
| `GROQ_API_KEY` | your Groq key |
| `LANGSMITH_API_KEY` | optional, leave `""` to skip tracing |

Don't touch the other values (terraform filled them: Redis / database / TensorZero addresses, guardrail id, Postgres password, a random `API_KEY`). Save.

Your API key (the password for the app):

```bash
./tf.sh output -raw api_key
```

Copy it somewhere safe (a password manager).

### 5. Restart once so the instance picks up the keys

The keys are read at boot. EC2 console → **Instances** → `research-relay-ec2` → **Instance state → Reboot**.

Wait ~2 minutes, then open `http://<public IP>/health`. You should see `{"status":"ok","redis":"ok"}`. Done! 🎉

---

## Daily use: Start → demo → Stop

### Option A: AWS console (easiest)

1. EC2 → **Instances** → tick `research-relay-ec2`
2. **Instance state → Start instance**
3. Wait until **Instance state = Running** and **Status check = 2/2**, then about 1–2 more minutes for the containers
4. Copy the **Public IPv4 address** (it's **new every time you Start**) → open `http://THAT_IP` in the browser
5. Demo time
6. **Instance state → Stop instance**. ← don't forget this one

### Option B: CloudShell commands

```bash
# find the instance id (once per CloudShell session)
ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=research-relay-ec2" \
  "Name=instance-state-name,Values=running,stopped,stopping,pending" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

# START + print the URL
aws ec2 start-instances --instance-ids $ID
aws ec2 wait instance-running --instance-ids $ID
echo "http://$(aws ec2 describe-instances --instance-ids $ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

# STOP
aws ec2 stop-instances --instance-ids $ID
```

> Why does the IP change? A fixed IP (Elastic IP) costs money even while the instance is stopped (~$3.6/month). A changing IP is free while stopped. For demos, copying a new IP is fine.

---

## Using the App

Open `http://<public IP>` in your browser, paste your API key in the key field, type a topic, pick text / PDF / JSON, click **Start Research**.

### API

Add `-H "X-API-Key: your-key"` to every call. Only `/health` and the frontend page work without it.

```bash
# start a job
curl -X POST http://<ip>/research -H "X-API-Key: your-key" -H "Content-Type: application/json" \
  -d '{"topic": "AI chip market 2025", "output_format": "text"}'

# poll the result
curl -H "X-API-Key: your-key" http://<ip>/result/<job_id>

# PDF
curl -H "X-API-Key: your-key" http://<ip>/result/<job_id>/pdf -o report.pdf

# session history, report diff, stats, health
curl -H "X-API-Key: your-key" http://<ip>/session/<session_id>
curl -H "X-API-Key: your-key" http://<ip>/diff/<topic>
curl -H "X-API-Key: your-key" http://<ip>/stats
curl http://<ip>/health

# LLM-as-judge on one job, or a batch on recent topics
curl -H "X-API-Key: your-key" http://<ip>/evaluate/<job_id>
curl -X POST -H "X-API-Key: your-key" -H "Content-Type: application/json" http://<ip>/run-evaluation -d '{}'
```

---

## Changing things later

| You want to… | Do this |
|---|---|
| Change a key (Gemini, Groq, LangSmith) | Edit the secret in Secrets Manager → **Reboot** the instance |
| Change the code | Edit the files → put the new folder in CloudShell (step 1) → `cd terraform && ./tf.sh apply` (uploads the new zip) → **Reboot** the instance |
| Allow only your own IP | `./tf.sh apply -var="allowed_cidr=YOUR_IP/32"` (find your IP at https://checkip.amazonaws.com) |

---

## Something's not working? Look inside the instance

No SSH needed. EC2 → select the instance → **Connect** → **Session Manager** tab → **Connect**. Then:

```bash
sudo journalctl -u research-relay --no-pager | tail -50    # did the boot script finish?
cd /opt/research-relay
sudo docker compose ps                                     # are all 4 containers "running"?
sudo docker compose logs app --tail 50                     # app errors
sudo docker compose logs tensorzero --tail 50              # Gemini / Groq errors (bad key?)
```

Common ones:

| You see | Means |
|---|---|
| Browser can't connect at all | Still booting (first boot = 10–15 min), or you're using the old IP |
| `/health` works but research fails | Keys still `REPLACE_ME`, or you didn't Reboot after adding them |
| `AccessDenied ... explicit deny` during apply | Your AWS Organization blocks a service. Send me the error |

---

## Tests

They don't need AWS: Redis is replaced by `fakeredis`, the embedding model by a tiny fake, and LLM / Bedrock calls by `monkeypatch`.

```bash
pip install -r requirements-dev.txt
pytest
```

| File | What it checks |
|---|---|
| `test_agents.py` | Critic YES/NO, full relay finishes, relay stops after max retries |
| `test_guardrails.py` | Bedrock "intervened" = blocked, INPUT/OUTPUT source |
| `test_auth.py` | Right key passes, wrong / missing key = 401, no key configured = 503 |
| `test_redis_parts.py` | Semantic cache hit/miss, session trimming, job queue, results |
| `test_output_eval.py` | PDF and JSON output, judge score parsing |
| `test_retry.py` | Retry then succeed, retry then give up |

---

## Tear Down Everything

In CloudShell:

```bash
cd Research-Relay/terraform     # or Research-Relay-EC2/terraform if you uploaded the zip
./tf.sh destroy
```

Type `yes`. This deletes the instance **and its disk (your database)**, the secret, the guardrail and the code bucket. The S3 state bucket stays; delete it in the S3 console if you want. Also delete the budget if you no longer need it.

---

## What's different from the ECS edition (and why)

| ECS edition (`Research-Relay-AWS`) | This edition |
|---|---|
| Load balancer + 2 Fargate tasks | 1 EC2 instance |
| ElastiCache Redis + RDS Postgres | Redis + Postgres containers on the same instance |
| GitHub Actions builds & deploys | The instance builds itself on boot |
| Runs 24/7, a few $ per day | Start/Stop, ~$3/month |
| Red team dashboard on port 8001 | **Not started** (saves RAM; port 8001 stays closed) |

> **Red team dashboard:** the `pyrit_dashboard/` folder is still here but not in `docker-compose.yml`. The 2 GB instance is tight, and the dashboard still has the known gap of not sending an API key (its attacks would show as `401` / "BLOCKED"). Ask if you want it added back.

# Process flow

These diagrams show what each command does, in the order it does it. Each diagram is a picture for quick reading, and the Mermaid source below it renders on GitHub and can be edited.

All four diagrams describe the same rule: **nothing changes in the directory unless a person asked for a live run**, and **every run, planned or real, leaves an audit record**.

## 1. The whole process

![Overview of the joiner, mover and leaver process](process-flow.png)

Reading the diagram:

* HR is the source of truth. The automation never decides who joins, moves or leaves. It carries out an approved change.
* The default is a dry run. A live run needs the explicit `-Execute` switch.
* Protected accounts (break-glass, administrators, accounts synced from on-premises Active Directory, the account running the tool) are refused at the worker level, so the same protection applies however the command is started.

```mermaid
flowchart TB
    subgraph PREP["1. Prepare and decide"]
        direction LR
        HR["HR approves a change<br/>and raises a ticket"] --> CSV["CSV file of joiners,<br/>movers and leavers"]
        CSV --> BATCH["Invoke-JmlBatch<br/>checks every row"]
        BATCH --> EXEC{"Was -Execute<br/>passed?"}
    end
    subgraph RUN["2. Run and record"]
        direction LR
        WORKERS["Joiner, mover or<br/>leaver command"] --> PROT{"Protected<br/>account?"}
        PROT -- "Yes" --> REFUSE["Refused<br/>and logged"]
        PROT -- "No" --> GRAPH["Microsoft Graph<br/>updates Entra ID<br/>(real runs only)"]
        GRAPH --> CHECKLIST["Leaver checklist<br/>for manual steps"]
        GRAPH --> AUDIT[("JSON audit log<br/>no secrets")]
        REFUSE --> AUDIT
    end
    EXEC -- "No (default)" --> DRY["Dry run: shows the plan,<br/>changes nothing"]
    EXEC -- "Yes" --> GATES["Safety gates: approval reference,<br/>size limits, due date"]
    DRY --> WORKERS
    GATES --> WORKERS

    classDef human fill:#fff4d6,stroke:#b58105,color:#222;
    classDef safe fill:#e3f1e3,stroke:#2e7d32,color:#222;
    classDef stop fill:#fde4e4,stroke:#b3261e,color:#222;
    classDef out fill:#e4eefb,stroke:#1f5fae,color:#222;
    class HR,CSV human;
    class DRY,GATES safe;
    class REFUSE stop;
    class AUDIT,CHECKLIST out;
    style PREP fill:#f6f6f6,stroke:#999,color:#222
    style RUN fill:#f6f6f6,stroke:#999,color:#222
```

## 2. Joiner

![Joiner flow](process-joiner.png)

The joiner command is safe to run twice. If an account with the same employee ID already exists, it is reconciled instead of recreated. A disabled account is never re-enabled automatically, because a re-hire needs a person to review it.

```mermaid
flowchart TD
    S["New-JmlJoiner<br/>HR record in"] --> V{"Record valid?<br/>department mapped,<br/>country code, name"}
    V -- "No" --> F1["Fail before any change"]
    V -- "Yes" --> M{"Manager exists<br/>and is enabled?"}
    M -- "No" --> F1
    M -- "Yes" --> E{"Account with this<br/>employee ID already exists?"}
    E -- "Yes" --> P{"Protected or<br/>disabled account?"}
    P -- "Yes" --> R["Refuse and log"]
    P -- "No" --> REC["Reconcile: add missing<br/>attributes, manager, groups"]
    E -- "No" --> U["Choose a free sign-in name<br/>(alex.morgan, then alex.morgan2)"]
    U --> C["Create the user with a random<br/>one-time password and forced change"]
    C --> MG["Set the manager"]
    REC --> MG
    MG --> G["Add baseline, department<br/>and role groups"]
    G --> L["Add the licence group<br/>(group-based licensing<br/>assigns the licence)"]
    L --> H["Hand the password to your secure channel<br/>never written to the log"]
    H --> A[("Audit log")]

    classDef stop fill:#fde4e4,stroke:#b3261e,color:#222;
    classDef ok fill:#e3f1e3,stroke:#2e7d32,color:#222;
    class F1,R stop;
    class C,G,L ok;
```

## 3. Mover

![Mover flow](process-mover.png)

Only groups named in `config/department-groups.json` and `config/licences.json` are ever added or removed. Access granted by hand elsewhere is left alone. The new licence group is added before the old one is removed, so licensing never has a gap.

```mermaid
flowchart TD
    S["Move-JmlUser<br/>new department, title,<br/>manager or office"] --> P{"Protected, synced<br/>or disabled account?"}
    P -- "Yes" --> R["Refuse and log"]
    P -- "No" --> D["Work out the groups wanted<br/>for the new department and title"]
    D --> OK{"Department<br/>in the mapping?"}
    OK -- "No" --> F["Fail and change nothing"]
    OK -- "Yes" --> ATT["Update changed attributes<br/>and manager"]
    ATT --> ADD["Add the groups the person<br/>is missing, new licence group first"]
    ADD --> REM["Remove managed groups from<br/>the old role that are no longer wanted"]
    REM --> KEEP["Baseline groups kept.<br/>Groups outside the mapping<br/>are never touched"]
    KEEP --> A[("Audit log")]

    classDef stop fill:#fde4e4,stroke:#b3261e,color:#222;
    classDef ok fill:#e3f1e3,stroke:#2e7d32,color:#222;
    class R,F stop;
    class ADD,REM,KEEP ok;
```

## 4. Leaver

![Leaver flow](process-leaver.png)

The account is never deleted by this tool. Sign-in is blocked and sessions are revoked first, because that is the step that actually stops access. Licences are held back until the mailbox has been converted to a shared mailbox, because an unlicensed mailbox cannot be converted and would be lost after the grace period. The checklist lists the steps that Microsoft Graph cannot do.

```mermaid
flowchart TD
    S["Remove-JmlLeaver"] --> P{"Protected, synced,<br/>admin or your own account?"}
    P -- "Yes" --> R["Refuse and log"]
    P -- "No" --> SN["Snapshot: manager, direct reports,<br/>groups, sign-in methods"]
    SN --> DIS["Block sign-in"]
    DIS --> REV["Revoke all sessions<br/>and refresh tokens"]
    REV --> MFA["Remove registered MFA methods<br/>(optional, default on)"]
    MFA --> GRP["Remove from groups the<br/>automation may change"]
    GRP --> GATE{"Mailbox converted<br/>to a shared mailbox?"}
    GATE -- "Not yet" --> HOLD["Hold licences.<br/>Re-run once the mailbox<br/>has been converted"]
    GATE -- "Yes" --> LIC["Reclaim direct licences<br/>and licence group"]
    HOLD --> CK["Write the checklist"]
    LIC --> CK
    CK --> MAN["People finish the manual steps:<br/>mailbox, OneDrive, devices,<br/>applications, handover"]
    MAN --> A[("Audit log")]

    classDef stop fill:#fde4e4,stroke:#b3261e,color:#222;
    classDef ok fill:#e3f1e3,stroke:#2e7d32,color:#222;
    classDef human fill:#fff4d6,stroke:#b58105,color:#222;
    class R stop;
    class DIS,REV,MFA,GRP,LIC ok;
    class HOLD,MAN human;
```

## Regenerating the pictures

The PNG files are rendered from the Mermaid blocks above with the Mermaid command line tool (`mmdc`). On a Linux machine that runs as root, Chromium needs a small configuration file:

```json
{ "args": ["--no-sandbox", "--disable-setuid-sandbox"] }
```

```text
mmdc -p puppeteer.json -i diagram.mmd -o process-flow.png -b white -w 1400 -s 2
```

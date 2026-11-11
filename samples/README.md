# Sample data

All records here are synthetic. The organisation `northwind.example` and every person in these files are invented.

| File | Contents |
|---|---|
| `events.sample.csv` | One file with every event type, a protected account and a deliberately incomplete row. Use this for `Invoke-JmlBatch`. |
| `joiners.sample.csv` | Four new starters, one of them dated far enough ahead to be deferred. |
| `movers.sample.csv` | A department change and a job title change. |
| `leavers.sample.csv` | One leaver whose mailbox is still to be converted and one whose mailbox has already been converted. |

Two rows in `events.sample.csv` are there to show the safety checks working:

* `breakglass01@northwind.example` matches the protected account list, so the run refuses it.
* The last row has no `UsageLocation`, so it is reported as invalid and the rest of the file carries on.

Dates are `yyyy-MM-dd`. Joiners are prepared `joiner.leadDays` days before the start date (three by default). Use `-AsOfDate 2026-12-01` to rehearse the file as if it were that day.

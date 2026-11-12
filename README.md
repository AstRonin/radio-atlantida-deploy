# radio-atlantida-deploy

Production stack of Radio Atlantida: the Compose file, configuration copies,
the Windows host installer, and the update tool. No application code; the
backend and frontend run as prebuilt images from GitHub Container Registry.

The runbook (install, update, rollback, restore, maintenance, backups) is
written in Phase D7 of `docs/deploy-init-plan.md`. Until then, see that plan
and `docs/tech-design.md` §9.

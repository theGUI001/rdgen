from django.db import models

class GithubRun(models.Model):
    id = models.IntegerField(verbose_name="ID",primary_key=True)
    uuid = models.CharField(verbose_name="uuid", max_length=100)
    status = models.CharField(verbose_name="status", max_length=100)
    github_run_id = models.BigIntegerField(null=True, blank=True)


class BuildBatch(models.Model):
    """A group of custom-client builds scheduled together for several platforms.

    Powers the "schedule builds for multiple OSes" view: one shared
    configuration fans out into one BuildJob per requested platform.
    """
    uuid = models.CharField(max_length=100, unique=True, db_index=True)
    label = models.CharField(max_length=200, blank=True, default="")
    filename = models.CharField(max_length=200, blank=True, default="rustdesk")
    engine = models.CharField(max_length=20, default="docker")
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.label or self.filename} ({self.uuid})"


class BuildJob(models.Model):
    """One platform build inside a BuildBatch.

    Each job carries its own uuid, which is also the GithubRun uuid, so the
    existing per-run status machinery works unchanged for batch jobs.
    """
    batch = models.ForeignKey(BuildBatch, related_name="jobs", on_delete=models.CASCADE)
    platform = models.CharField(max_length=30)
    uuid = models.CharField(max_length=100, db_index=True)
    filename = models.CharField(max_length=200, blank=True, default="rustdesk")
    status = models.CharField(max_length=100, default="queued")
    log_url = models.CharField(max_length=500, blank=True, default="")
    error = models.CharField(max_length=500, blank=True, default="")
    position = models.IntegerField(default=0)

    class Meta:
        ordering = ["position", "id"]

    def __str__(self):
        return f"{self.platform} build for {self.batch_id} ({self.status})"

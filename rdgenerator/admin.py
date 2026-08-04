from django.contrib import admin
from .models import GithubRun, BuildBatch, BuildJob


class BuildJobInline(admin.TabularInline):
    model = BuildJob
    extra = 0


@admin.register(BuildBatch)
class BuildBatchAdmin(admin.ModelAdmin):
    list_display = ("uuid", "label", "filename", "engine", "created_at")
    search_fields = ("uuid", "label", "filename")
    inlines = [BuildJobInline]


@admin.register(BuildJob)
class BuildJobAdmin(admin.ModelAdmin):
    list_display = ("batch", "platform", "status", "uuid")
    list_filter = ("platform", "status")
    search_fields = ("uuid",)


admin.site.register(GithubRun)

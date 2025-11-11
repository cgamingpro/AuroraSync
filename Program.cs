// Program.cs
using System.Xml.Linq;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var baseDir = Path.Combine("E:\\wg\\phoneBackup", "Backups", "Received");
Directory.CreateDirectory(baseDir);
var metaPath = Path.Combine("E:\\wg\\phoneBackup", "Backups", "metadata.json");

// Metadata: maps relativePath -> FileMeta
Dictionary<string, FileMeta> metadata = LoadMetadata();

Dictionary<string, FileMeta> LoadMetadata()
{
    try
    {
        if (!File.Exists(metaPath)) return new Dictionary<string, FileMeta>();
        var j = File.ReadAllText(metaPath);
        return System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, FileMeta>>(j)
               ?? new Dictionary<string, FileMeta>();
    }
    catch
    {
        return new Dictionary<string, FileMeta>();
    }
}

void SaveMetadata()
{
    var j = System.Text.Json.JsonSerializer.Serialize(metadata, new System.Text.Json.JsonSerializerOptions { WriteIndented = true });
    Directory.CreateDirectory(Path.GetDirectoryName(metaPath)!);
    File.WriteAllText(metaPath, j);
}

string NormalizeClientRel(string clientRel, string clientPath)
{
    // If client provided a rel use it (prefer), otherwise derive from path.
    if (!string.IsNullOrWhiteSpace(clientRel)) return clientRel.Replace('\\', '/').TrimStart('/');
    if (string.IsNullOrWhiteSpace(clientPath)) return Path.GetFileName(clientPath) ?? Guid.NewGuid().ToString();
    var marker = "storage/emulated/0";
    var p = clientPath.Replace('\\', '/');
    var idx = p.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
    if (idx >= 0)
    {
        return p.Substring(idx + marker.Length).TrimStart('/');
    }
    if (p.StartsWith("/")) p = p.TrimStart('/');
    return p;
}

app.MapGet("/", () => Results.Ok("AuroraSync server running."));

app.MapPost("/sync-list", async (HttpRequest request) =>
{
    try
    {
        var body = await new StreamReader(request.Body).ReadToEndAsync();
        if (string.IsNullOrWhiteSpace(body)) return Results.BadRequest("Empty body");

        var doc = XDocument.Parse(body);
        var clientFiles = doc.Root?.Elements("file")
            .Select(x => new ClientFile
            {
                rel = (string?)x.Element("rel") ?? "",
                path = (string?)x.Element("path") ?? "",
                name = (string?)x.Element("name") ?? "",
                lastModified = long.TryParse((string?)x.Element("lastModified") ?? "0", out var t) ? t : 0L,
                size = long.TryParse((string?)x.Element("size") ?? "0", out var s) ? s : 0L
            })
            .ToList() ?? new List<ClientFile>();

        var needToUpload = new List<(string rel, long lastModified, long size)>();

        foreach (var cf in clientFiles)
        {
            var rel = NormalizeClientRel(cf.rel, cf.path);
            metadata.TryGetValue(rel, out var meta);
            var serverLast = meta?.lastModified ?? -1L;
            var serverSize = meta?.size ?? -1L;

            // If missing, or client has newer lastModified, or size differs => request upload
            if (meta == null || cf.lastModified > serverLast || cf.size != serverSize)
            {
                needToUpload.Add((rel, cf.lastModified, cf.size));
            }
        }

        var respDoc = new XDocument(new XElement("files",
            needToUpload.Select(f => new XElement("file",
                new XElement("rel", f.rel),
                new XElement("lastModified", f.lastModified.ToString()),
                new XElement("size", f.size.ToString())
            ))
        ));

        // debug log
        Console.WriteLine($"Received inventory ({clientFiles.Count}). Need {needToUpload.Count} files.");
        return Results.Content(respDoc.ToString(), "application/xml");
    }
    catch (Exception ex)
    {
        Console.WriteLine("sync-list error: " + ex);
        return Results.Problem(ex.Message);
    }
});

app.MapPost("/upload", async (HttpRequest request) =>
{
    try
    {
        if (!request.HasFormContentType) return Results.BadRequest("Expected multipart/form-data");
        var form = await request.ReadFormAsync();
        var files = form.Files;
        if (files.Count == 0) return Results.BadRequest("No files uploaded.");

        var saved = new List<string>();

        foreach (var file in files)
        {
            var clientRel = form["rel"].ToString(); // client-provided relative path (preferred)
            var clientPath = form["filepath"].ToString();
            var clientLast = long.TryParse(form["lastModified"].ToString(), out var lm) ? lm : 0L;
            var clientSize = long.TryParse(form["size"].ToString(), out var sz) ? sz : -1L;

            var rel = NormalizeClientRel(clientRel, clientPath);
            if (string.IsNullOrWhiteSpace(rel)) rel = Path.GetFileName(file.FileName) ?? Guid.NewGuid().ToString();

            var outPath = Path.Combine(baseDir, rel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);

            await using var fs = new FileStream(outPath, FileMode.Create, FileAccess.Write);
            await file.CopyToAsync(fs);
            saved.Add(rel);

            var actualSize = new FileInfo(outPath).Length;
            metadata[rel] = new FileMeta { lastModified = clientLast > 0 ? clientLast : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), size = actualSize };
            Console.WriteLine($"Saved {rel} ({actualSize} bytes).");
        }

        SaveMetadata();
        return Results.Ok(new { savedCount = saved.Count, saved });
    }
    catch (Exception ex)
    {
        Console.WriteLine("upload error: " + ex);
        return Results.Problem(ex.Message);
    }
});

app.Run("http://0.0.0.0:5050");

record ClientFile
{
    public string rel = "";
    public string path = "";
    public string name = "";
    public long lastModified;
    public long size;
}

record FileMeta
{
    public long lastModified;
    public long size;
}

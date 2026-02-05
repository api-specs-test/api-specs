import ballerina/io;
import ballerina/os;
import ballerina/http;
import ballerina/file;
import ballerina/time;
import ballerina/lang.regexp;
import ballerina/crypto;
import ballerinax/github;

// Versioning strategy types
const RELEASE_TAG = "release-tag";
const FILE_BASED = "file-based";
const ROLLOUT_BASED = "rollout-based";

// Repository record type
type Repository record {|
    string vendor;
    string api;
    string owner;
    string repo;
    string name;
    string lastVersion;
    string specPath;
    string releaseAssetName;
    string baseUrl;
    string documentationUrl;
    string description;
    string[] tags;
    string versioningStrategy = RELEASE_TAG; // Default to release-tag
    string? branch = (); // For file-based and rollout-based strategies
    string? connectorRepo = (); // Optional: connector repository reference
    string? lastContentHash = (); // SHA-256 hash of last downloaded content
|};

// Update result record
type UpdateResult record {|
    Repository repo;
    string oldVersion;
    string newVersion;
    string apiVersion;
    string downloadUrl;
    string localPath;
    boolean contentChanged;
    string updateType; // "version" or "content" or "both"
|};

// Check for version updates
function hasVersionChanged(string oldVersion, string newVersion) returns boolean {
    return oldVersion != newVersion;
}

// Check for content updates
function hasContentChanged(string? oldHash, string newHash) returns boolean {
    if oldHash is () || oldHash == "" {
        return true; // First time download
    }
    return oldHash != newHash;
}

// Calculate SHA-256 hash of content
function calculateHash(string content) returns string {
    byte[] contentBytes = content.toBytes();
    byte[] hashBytes = crypto:hashSha256(contentBytes);
    return hashBytes.toBase16();
}

// Extract rollout number from path (e.g., "Rollouts/148901/v4" -> "148901")
function extractRolloutNumber(string path) returns string|error {
    string[] parts = regexp:split(re `/`, path);
    foreach int i in 0 ..< parts.length() {
        if parts[i] == "Rollouts" && i + 1 < parts.length() {
            return parts[i + 1];
        }
    }
    return error("Could not extract rollout number from path");
}

// List directory contents from GitHub
function listGitHubDirectory(string owner, string repo, string branch, string path) returns string[]|error {
    string url = string `https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}`;

    http:Client httpClient = check new (url);
    http:Response response = check httpClient->get("");

    if response.statusCode != 200 {
        return error(string `Failed to list directory: HTTP ${response.statusCode}`);
    }

    json|error content = response.getJsonPayload();
    if content is error {
        return error("Failed to parse directory listing");
    }

    if content is json[] {
        string[] names = [];
        foreach json item in content {
            if item is map<json> {
                json? nameJson = item["name"];
                if nameJson is string {
                    names.push(nameJson);
                }
            }
        }
        return names;
    }

    return error("Unexpected response format from GitHub API");
}

// Find latest rollout number in a directory
function findLatestRollout(string owner, string repo, string branch, string basePath) returns string|error {
    io:println(string `  🔍 Searching for rollouts in ${basePath}...`);

    string[] contents = check listGitHubDirectory(owner, repo, branch, basePath);

    int maxRollout = 0;
    foreach string item in contents {
        // Try to parse as integer
        int|error rolloutNum = int:fromString(item);
        if rolloutNum is int && rolloutNum > maxRollout {
            maxRollout = rolloutNum;
        }
    }

    if maxRollout == 0 {
        return error("No rollout directories found");
    }

    io:println(string `  ✅ Found latest rollout: ${maxRollout}`);
    return maxRollout.toString();
}

// Extract version from OpenAPI spec content (works for both YAML and JSON)
function extractApiVersion(string content) returns string|error {
    // Split content by lines
    string[] lines = regexp:split(re `\n`, content);
    boolean inInfoSection = false;

    foreach string line in lines {
        string trimmedLine = line.trim();

        // Check for JSON format: "version": "value"
        if trimmedLine.startsWith("\"version\":") || trimmedLine.startsWith("'version':") {
            string[] parts = regexp:split(re `:`, trimmedLine);
            if parts.length() >= 2 {
                string versionValue = parts[1].trim();
                // Remove quotes, commas, and whitespace
                versionValue = removeQuotes(versionValue);
                versionValue = regexp:replace(re `,`, versionValue, "").trim();
                if versionValue.length() > 0 {
                    return versionValue;
                }
            }
        }

        // Check for YAML format
        if trimmedLine == "info:" {
            inInfoSection = true;
            continue;
        }

        if inInfoSection {
            // Exit info section if we hit another top-level key
            if !line.startsWith(" ") && !line.startsWith("\t") && trimmedLine != "" && !trimmedLine.startsWith("#") {
                break;
            }

            // Look for version field in YAML
            if trimmedLine.startsWith("version:") {
                string[] parts = regexp:split(re `:`, trimmedLine);
                if parts.length() >= 2 {
                    string versionValue = parts[1].trim();
                    versionValue = removeQuotes(versionValue);
                    return versionValue;
                }
            }
        }
    }

    return error("Could not extract API version from spec");
}

// Download OpenAPI spec from release asset or repo
function downloadSpec(github:Client githubClient, string owner, string repo,
                     string assetName, string tagName, string specPath) returns string|error {

    io:println(string `  📥 Downloading ${assetName}...`);

    string? downloadUrl = ();

    // Try to get from release assets first
    github:Release|error release = githubClient->/repos/[owner]/[repo]/releases/tags/[tagName]();

    if release is github:Release {
        github:ReleaseAsset[]? assets = release.assets;
        if assets is github:ReleaseAsset[] {
            foreach github:ReleaseAsset asset in assets {
                if asset.name == assetName {
                    downloadUrl = asset.browser_download_url;
                    io:println(string `  ✅ Found in release assets`);
                    break;
                }
            }
        }
    }

    // If not found in assets, try direct download from repo
    if downloadUrl is () {
        io:println(string `  ℹ️  Not in release assets, downloading from repository...`);
        downloadUrl = string `https://raw.githubusercontent.com/${owner}/${repo}/${tagName}/${specPath}`;
    }

    // Download the file
    http:Client httpClient = check new (<string>downloadUrl);
    http:Response response = check httpClient->get("");

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${<string>downloadUrl}`);
    }

    // Get content
    string|byte[]|error content = response.getTextPayload();

    if content is error {
        return error("Failed to get content from response");
    }

    string textContent;
    if content is string {
        textContent = content;
    } else {
        // Convert bytes to string
        textContent = check string:fromBytes(content);
    }

    io:println(string `  ✅ Downloaded spec`);
    return textContent;
}

// Download spec directly from branch (for file-based versioning)
function downloadSpecFromBranch(string owner, string repo, string branch, string specPath) returns string|error {
    io:println(string `  📥 Downloading ${specPath} from ${branch} branch...`);

    string downloadUrl = string `https://raw.githubusercontent.com/${owner}/${repo}/${branch}/${specPath}`;

    // Download the file
    http:Client httpClient = check new (downloadUrl);
    http:Response response = check httpClient->get("");

    if response.statusCode != 200 {
        return error(string `Failed to download: HTTP ${response.statusCode} from ${downloadUrl}`);
    }

    // Get content
    string|byte[]|error content = response.getTextPayload();

    if content is error {
        return error("Failed to get content from response");
    }

    string textContent;
    if content is string {
        textContent = content;
    } else {
        // Convert bytes to string
        textContent = check string:fromBytes(content);
    }

    io:println(string `  ✅ Downloaded spec`);
    return textContent;
}

// Save spec to file
function saveSpec(string content, string localPath) returns error? {
    // Create directory if it doesn't exist
    string dirPath = check file:parentPath(localPath);
    if !check file:test(dirPath, file:EXISTS) {
        check file:createDir(dirPath, file:RECURSIVE);
    }

    // Write as openapi.yaml (always YAML format)
    check io:fileWriteString(localPath, content);
    io:println(string `  ✅ Saved to ${localPath}`);
    return;
}

// Create metadata.json file
function createMetadataFile(Repository repo, string version, string dirPath) returns error? {
    json metadata = {
        "name": repo.name,
        "baseUrl": repo.baseUrl,
        "documentationUrl": repo.documentationUrl,
        "description": repo.description,
        "tags": repo.tags
    };

    string metadataPath = string `${dirPath}/.metadata.json`;
    check io:fileWriteJson(metadataPath, metadata);
    io:println(string `  ✅ Created metadata at ${metadataPath}`);
    return;
}

// Get current repository info from git
function getCurrentRepo() returns [string, string]|error {
    string? githubRepo = os:getEnv("GITHUB_REPOSITORY");
    if githubRepo is string {
        string[] parts = regexp:split(re `/`, githubRepo);
        if parts.length() == 2 {
            return [parts[0], parts[1]];
        }
    }
    return error("Could not determine repository from GITHUB_REPOSITORY env var");
}

// Create Pull Request
function createPullRequest(github:Client githubClient, string owner, string repo,
                          string branchName, string baseBranch, string title,
                          string body) returns string|error {

    io:println("\n🔗 Creating Pull Request...");

    github:PullRequest pr = check githubClient->/repos/[owner]/[repo]/pulls.post({
        title: title,
        body: body,
        head: branchName,
        base: baseBranch
    });

    string prUrl = pr.html_url;
    io:println(string `✅ Pull Request created successfully!`);
    io:println(string `🔗 PR URL: ${prUrl}`);

    // Add labels to the PR
    int prNumber = pr.number;
    _ = check githubClient->/repos/[owner]/[repo]/issues/[prNumber]/labels.post({
        labels: ["openapi-update", "automated", "dependencies"]
    });
    io:println("🏷️  Added labels to PR");

    return prUrl;
}

// Remove quotes from string
function removeQuotes(string s) returns string {
    string result = "";
    foreach int i in 0 ..< s.length() {
        string c = s.substring(i, i + 1);
        if c != "\"" && c != "'" {
            result += c;
        }
    }
    return result;
}

// Process repository with release-tag versioning strategy
function processReleaseTagRepo(github:Client githubClient, Repository repo) returns UpdateResult|error? {
    io:println(string `Checking: ${repo.name} (${repo.vendor}/${repo.api}) [Release-Tag Strategy]`);

    // Get latest release
    github:Release|error latestRelease = githubClient->/repos/[repo.owner]/[repo.repo]/releases/latest();

    if latestRelease is github:Release {
        string tagName = latestRelease.tag_name;
        string? publishedAt = latestRelease.published_at;
        boolean isDraft = latestRelease.draft;
        boolean isPrerelease = latestRelease.prerelease;

        if isPrerelease || isDraft {
            io:println(string `  ⏭️  Skipping pre-release: ${tagName}`);
            return ();
        }

        io:println(string `  Latest release tag: ${tagName}`);
        if publishedAt is string {
            io:println(string `  Published: ${publishedAt}`);
        }

        boolean versionChanged = hasVersionChanged(repo.lastVersion, tagName);

        // Download the spec to check content
        string|error specContent = downloadSpec(
            githubClient,
            repo.owner,
            repo.repo,
            repo.releaseAssetName,
            tagName,
            repo.specPath
        );

        if specContent is error {
            io:println("  ❌ Download failed: " + specContent.message());
            return error(specContent.message());
        }

        // Calculate content hash
        string contentHash = calculateHash(specContent);
        boolean contentChanged = hasContentChanged(repo.lastContentHash, contentHash);

        io:println(string `  📊 Content Hash: ${contentHash.substring(0, 16)}...`);

        if versionChanged || contentChanged {
            string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
            io:println(string `  ✅ UPDATE DETECTED! (Type: ${updateType})`);

            // Extract API version from spec
            string apiVersion = "";
            var apiVersionResult = extractApiVersion(specContent);
            if apiVersionResult is error {
                io:println("  ⚠️  Could not extract API version, using tag: " + tagName);
                apiVersion = tagName.startsWith("v") ? tagName.substring(1) : tagName;
            } else {
                apiVersion = apiVersionResult;
                io:println("  📌 API Version: " + apiVersion);
            }

            // Structure: openapi/{vendor}/{api}/{apiVersion}/
            string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;
            string localPath = versionDir + "/openapi.yaml";

            // Save the spec
            error? saveResult = saveSpec(specContent, localPath);
            if saveResult is error {
                io:println("  ❌ Save failed: " + saveResult.message());
                return error(saveResult.message());
            }

            // Create metadata.json
            error? metadataResult = createMetadataFile(repo, apiVersion, versionDir);
            if metadataResult is error {
                io:println("  ⚠️  Metadata creation failed: " + metadataResult.message());
            }

            // Update the repo record
            string oldVersion = repo.lastVersion;
            repo.lastVersion = tagName;
            repo.lastContentHash = contentHash;

            // Return the update result
            return {
                repo: repo,
                oldVersion: oldVersion,
                newVersion: tagName,
                apiVersion: apiVersion,
                downloadUrl: "https://github.com/" + repo.owner + "/" + repo.repo + "/releases/tag/" + tagName,
                localPath: localPath,
                contentChanged: contentChanged,
                updateType: updateType
            };
        } else {
            io:println(string `  ℹ️  No updates (version: ${repo.lastVersion}, content unchanged)`);
            return ();
        }
    } else {
        string errorMsg = latestRelease.message();
        if errorMsg.includes("404") {
            io:println(string `  ❌ Error: No releases found for ${repo.owner}/${repo.repo}`);
        } else if errorMsg.includes("401") || errorMsg.includes("403") {
            io:println(string `  ❌ Error: Authentication failed`);
        } else {
            io:println(string `  ❌ Error: ${errorMsg}`);
        }
        return error(errorMsg);
    }
}

// Process repository with file-based versioning strategy
function processFileBasedRepo(Repository repo) returns UpdateResult|error? {
    io:println(string `Checking: ${repo.name} (${repo.vendor}/${repo.api}) [File-Based Strategy]`);

    string branch = repo.branch is string ? <string>repo.branch : "master";
    io:println(string `  Branch: ${branch}`);
    io:println(string `  Current tracked version: ${repo.lastVersion}`);

    // Download the spec from branch
    string|error specContent = downloadSpecFromBranch(
        repo.owner,
        repo.repo,
        branch,
        repo.specPath
    );

    if specContent is error {
        io:println("  ❌ Download failed: " + specContent.message());
        return error(specContent.message());
    }

    // Calculate content hash
    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(repo.lastContentHash, contentHash);

    io:println(string `  📊 Content Hash: ${contentHash.substring(0, 16)}...`);

    // Extract API version from spec content
    string|error apiVersionResult = extractApiVersion(specContent);

    if apiVersionResult is error {
        io:println("  ❌ Could not extract API version from spec content");
        io:println("  ⚠️  Skipping this repository - please check the spec format");
        return error("Cannot extract version from spec");
    }

    string apiVersion = apiVersionResult;
    io:println(string `  📌 Current API Version in spec: ${apiVersion}`);

    boolean versionChanged = hasVersionChanged(repo.lastVersion, apiVersion);

    // Check if version has changed OR content has changed
    if versionChanged || contentChanged {
        string updateType = versionChanged && contentChanged ? "both" : (versionChanged ? "version" : "content");
        io:println(string `  ✅ UPDATE DETECTED! (${repo.lastVersion} → ${apiVersion}, Type: ${updateType})`);

        // Structure: openapi/{vendor}/{api}/{apiVersion}/
        string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/" + apiVersion;
        string localPath = versionDir + "/openapi.yaml";

        // For content-only changes in same version, REPLACE existing files
        if !versionChanged && contentChanged {
            io:println(string `  🔄 Content update in same version ${apiVersion} - replacing existing files`);
        }

        // Save the spec (will overwrite if exists)
        error? saveResult = saveSpec(specContent, localPath);
        if saveResult is error {
            io:println("  ❌ Save failed: " + saveResult.message());
            return error(saveResult.message());
        }

        // Create/update metadata.json
        error? metadataResult = createMetadataFile(repo, apiVersion, versionDir);
        if metadataResult is error {
            io:println("  ⚠️  Metadata creation failed: " + metadataResult.message());
        }

        // Update the repo record
        string oldVersion = repo.lastVersion;
        repo.lastVersion = apiVersion;
        repo.lastContentHash = contentHash;

        // Return the update result
        return {
            repo: repo,
            oldVersion: oldVersion,
            newVersion: apiVersion,
            apiVersion: apiVersion,
            downloadUrl: string `https://github.com/${repo.owner}/${repo.repo}/blob/${branch}/${repo.specPath}`,
            localPath: localPath,
            contentChanged: contentChanged,
            updateType: updateType
        };
    } else {
        io:println(string `  ℹ️  No updates (version: ${apiVersion}, content unchanged)`);
        return ();
    }
}

// Process repository with rollout-based versioning strategy (for HubSpot)
function processRolloutBasedRepo(Repository repo) returns UpdateResult|error? {
    io:println(string `Checking: ${repo.name} (${repo.vendor}/${repo.api}) [Rollout-Based Strategy]`);

    string branch = repo.branch is string ? <string>repo.branch : "main";
    io:println(string `  Branch: ${branch}`);
    io:println(string `  Current tracked rollout: ${repo.lastVersion}`);

    // Extract the base path to the Rollouts directory
    string[] pathParts = regexp:split(re `/Rollouts/`, repo.specPath);
    if pathParts.length() < 2 {
        io:println("  ❌ Invalid path format - cannot find Rollouts directory");
        return error("Invalid rollout path format");
    }

    string basePath = pathParts[0] + "/Rollouts";

    // Find the latest rollout number
    string|error latestRollout = findLatestRollout(repo.owner, repo.repo, branch, basePath);

    if latestRollout is error {
        io:println("  ❌ Failed to find rollouts: " + latestRollout.message());
        return error(latestRollout.message());
    }

    io:println(string `  📌 Latest rollout: ${latestRollout}`);

    boolean rolloutChanged = hasVersionChanged(repo.lastVersion, latestRollout);

    // Construct the spec path (either current or new)
    string[] afterRollouts = regexp:split(re `/Rollouts/[0-9]+/`, repo.specPath);
    string afterRolloutPath = afterRollouts.length() > 1 ? afterRollouts[1] : "";
    string currentSpecPath = rolloutChanged ?
        basePath + "/" + latestRollout + "/" + afterRolloutPath :
        repo.specPath;

    // Download the spec to check content
    string|error specContent = downloadSpecFromBranch(
        repo.owner,
        repo.repo,
        branch,
        currentSpecPath
    );

    if specContent is error {
        io:println("  ❌ Download failed: " + specContent.message());
        return error(specContent.message());
    }

    // Calculate content hash
    string contentHash = calculateHash(specContent);
    boolean contentChanged = hasContentChanged(repo.lastContentHash, contentHash);

    io:println(string `  📊 Content Hash: ${contentHash.substring(0, 16)}...`);

    // Check if rollout has changed OR content has changed
    if rolloutChanged || contentChanged {
        string updateType = rolloutChanged && contentChanged ? "both" : (rolloutChanged ? "rollout" : "content");
        io:println(string `  ✅ UPDATE DETECTED! (Rollout ${repo.lastVersion} → ${latestRollout}, Type: ${updateType})`);

        // Extract API version from spec
        string apiVersion = "";
        var apiVersionResult = extractApiVersion(specContent);
        if apiVersionResult is error {
            io:println("  ⚠️  Could not extract API version from spec, using rollout number");
            apiVersion = latestRollout;
        } else {
            apiVersion = apiVersionResult;
            io:println(string `  📌 API Version: ${apiVersion}`);
        }

        // Structure: openapi/{vendor}/{api}/rollout-{rolloutNumber}/
        string versionDir = "../openapi/" + repo.vendor + "/" + repo.api + "/rollout-" + latestRollout;
        string localPath = versionDir + "/openapi.yaml";

        // For content-only changes in same rollout, REPLACE existing files
        if !rolloutChanged && contentChanged {
            io:println(string `  🔄 Content update within rollout ${latestRollout} - replacing existing files`);
        }

        // Save the spec (will overwrite if exists for content-only updates)
        error? saveResult = saveSpec(specContent, localPath);
        if saveResult is error {
            io:println("  ❌ Save failed: " + saveResult.message());
            return error(saveResult.message());
        }

        // Create/update metadata.json
        error? metadataResult = createMetadataFile(repo, latestRollout, versionDir);
        if metadataResult is error {
            io:println("  ⚠️  Metadata creation failed: " + metadataResult.message());
        }

        // Update the repo record with new rollout and path
        string oldVersion = repo.lastVersion;
        repo.lastVersion = latestRollout;
        repo.specPath = currentSpecPath;
        repo.lastContentHash = contentHash;

        // Return the update result
        return {
            repo: repo,
            oldVersion: "rollout-" + oldVersion,
            newVersion: "rollout-" + latestRollout,
            apiVersion: "rollout-" + latestRollout,
            downloadUrl: string `https://github.com/${repo.owner}/${repo.repo}/blob/${branch}/${currentSpecPath}`,
            localPath: localPath,
            contentChanged: contentChanged,
            updateType: updateType
        };
    } else {
        io:println(string `  ℹ️  No updates (rollout: ${latestRollout}, content unchanged)`);
        return ();
    }
}

// Main monitoring function
public function main() returns error? {
    io:println("=== Dependabot OpenAPI Monitor ===");
    io:println("Starting OpenAPI specification monitoring...\n");

    // Get GitHub token
    string? token = os:getEnv("GH_TOKEN");
    if token is () {
        io:println("❌ Error: GH_TOKEN environment variable not set");
        io:println("Please set the GH_TOKEN environment variable before running this program.");
        return;
    }

    string tokenValue = <string>token;

    // Validate token
    if tokenValue.length() == 0 {
        io:println("❌ Error: GH_TOKEN is empty!");
        return;
    }

    io:println(string `🔍 Token loaded (length: ${tokenValue.length()})`);

    // Initialize GitHub client
    github:Client githubClient = check new ({
        auth: {
            token: tokenValue
        }
    });

    // Load repositories from repos.json
    json reposJson = check io:fileReadJson("../repos.json");
    Repository[] repos = check reposJson.cloneWithType();

    io:println(string `Found ${repos.length()} repositories to monitor.\n`);

    // Track updates
    UpdateResult[] updates = [];

    // Check each repository based on versioning strategy
    foreach Repository repo in repos {
        UpdateResult|error? result = ();

        if repo.versioningStrategy == RELEASE_TAG {
            result = processReleaseTagRepo(githubClient, repo);
        } else if repo.versioningStrategy == FILE_BASED {
            result = processFileBasedRepo(repo);
        } else if repo.versioningStrategy == ROLLOUT_BASED {
            result = processRolloutBasedRepo(repo);
        } else {
            io:println(string `⚠️  Unknown versioning strategy: ${repo.versioningStrategy}`);
        }

        if result is UpdateResult {
            updates.push(result);
        }

        io:println("");
    }

    // Report updates
    if updates.length() > 0 {
        io:println(string `\n🎉 Found ${updates.length()} updates:\n`);

        // Create update summary
        string[] updateSummary = [];
        foreach UpdateResult update in updates {
            string updateTypeEmoji = update.updateType == "both" ? "🔄" : (update.updateType == "content" ? "📝" : "🆕");
            string summary = string `${updateTypeEmoji} ${update.repo.vendor}/${update.repo.api}: ${update.oldVersion} → ${update.newVersion} (${update.updateType} update)`;
            io:println(summary);
            updateSummary.push(summary);
        }

        // Update repos.json
        check io:fileWriteJson("../repos.json", repos.toJson());
        io:println("\n✅ Updated repos.json with new versions and content hashes");

        // Write update summary
        string summaryContent = string:'join("\n", ...updateSummary);
        check io:fileWriteString("../UPDATE_SUMMARY.txt", summaryContent);

        // Get current date for branch name
        time:Utc currentTime = time:utcNow();
        string timestamp = string `${time:utcToString(currentTime).substring(0, 10)}-${currentTime[0]}`;
        string branchName = string `openapi-update-${timestamp}`;

        // Get repository info
        [string, string]|error repoInfo = getCurrentRepo();
        if repoInfo is error {
            io:println("⚠️  Could not create PR automatically. Changes are ready in working directory.");
            io:println("Please create a PR manually with the following branch name:");
            io:println(string `  ${branchName}`);
            return;
        }

        string owner = repoInfo[0];
        string repoName = repoInfo[1];

        // Create PR title and body
        time:Civil civil = time:utcToCivil(currentTime);
        string prTitle = string `Update OpenAPI Specifications - ${civil.year}-${civil.month}-${civil.day}`;

        // Build Files Changed section
        string filesChangedContent = "";
        foreach var u in updates {
            string updateTypeLabel = u.updateType == "both" ? "version + content" : u.updateType;
            filesChangedContent = filesChangedContent + "- `" + u.localPath + "` (" + updateTypeLabel + " update)\n";
        }

        string prBody = "## OpenAPI Specification Updates\n\n" +
            "This PR contains automated updates to OpenAPI specifications detected by the Dependabot monitor.\n\n" +
            "### Changes:\n" + summaryContent + "\n\n" +
            "### Files Changed:\n" + filesChangedContent + "\n" +
            "### Update Types:\n" +
            "- 🆕 **Version update**: New API version/rollout released (creates new directory)\n" +
            "- 📝 **Content update**: Changes within same version/rollout (replaces existing files)\n" +
            "- 🔄 **Both**: Version change + content modifications\n\n" +
            "### Important Notes:\n" +
            "- Content-only updates **replace** files in existing directories to maintain single source of truth\n" +
            "- Version/rollout changes create new directories to preserve history\n" +
            "- All changes are tracked via SHA-256 content hashing\n\n" +
            "### Checklist:\n" +
            "- [ ] Review specification changes\n" +
            "- [ ] Verify connector generation works\n" +
            "- [ ] Run tests\n" +
            "- [ ] Update documentation if needed\n\n" +
            "---\n" +
            "🤖 This PR was automatically generated by the OpenAPI Dependabot";

        // Create the PR
        string|error prUrl = createPullRequest(
            githubClient,
            owner,
            repoName,
            branchName,
            "main",
            prTitle,
            prBody
        );

        if prUrl is string {
            io:println("\n✨ Done! Review the PR at: " + prUrl);
        } else {
            io:println("\n⚠️  PR creation failed: " + prUrl.message());
            io:println("Changes are committed. Please create PR manually.");
        }

    } else {
        io:println("✨ All specifications are up-to-date!");
    }
}

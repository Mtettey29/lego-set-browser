import json
import os
import sys

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

ENDPOINT = "https://cosmos-lego-sets.documents.azure.com:443/"
DATABASE = "LegoDatabase"
CONTAINER = "legoSets"
SEED_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "src",
    "azure_function",
    "lego_seed.json",
)


def main():
    with open(SEED_PATH, "r", encoding="utf-8") as f:
        items = json.load(f)
    print(f"Loaded {len(items)} items from {SEED_PATH}")

    credential = DefaultAzureCredential()
    client = CosmosClient(ENDPOINT, credential=credential)
    container = client.get_database_client(DATABASE).get_container_client(CONTAINER)

    upserted = 0
    for item in items:
        item["id"] = str(item["set_number"])
        container.upsert_item(item)
        upserted += 1
        print(f"  upserted {item['id']} - {item['name']}")

    print(f"Upserted {upserted} docs")

    count = list(
        container.query_items(
            query="SELECT VALUE COUNT(1) FROM c",
            enable_cross_partition_query=True,
        )
    )[0]
    print(f"Container now contains {count} documents")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)

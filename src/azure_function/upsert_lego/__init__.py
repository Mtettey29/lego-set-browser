import os
import json
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient
import azure.functions as func


def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        data = req.get_json()
        if not isinstance(data, list):
            return func.HttpResponse('Expected JSON array', status_code=400)

        endpoint = os.environ.get('COSMOS_ENDPOINT')
        database_name = os.environ.get('COSMOS_DATABASE')
        container_name = os.environ.get('COSMOS_CONTAINER')
        if not endpoint or not database_name or not container_name:
            return func.HttpResponse('Cosmos env vars not set', status_code=500)

        credential = DefaultAzureCredential()
        client = CosmosClient(endpoint, credential=credential)
        database = client.get_database_client(database_name)
        container = database.get_container_client(container_name)

        for item in data:
            # Map set_number to id (string)
            set_num = item.get('set_number')
            if set_num is None:
                # require set_number
                continue
            item['id'] = str(set_num)
            # Ensure expected fields exist; upsert will create or replace
            container.upsert_item(item)

        return func.HttpResponse(status_code=204)
    except Exception as e:
        return func.HttpResponse(f'Error: {str(e)}', status_code=500)

using UnityEngine;

public class Bootstrap : MonoBehaviour
{
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    static void Init()
    {
        GameObject cube = GameObject.CreatePrimitive(PrimitiveType.Cube);
        cube.name = "TestCube";
        cube.transform.position = new Vector3(0f, 1f, 3f);
        cube.transform.localScale = Vector3.one * 0.8f;
        var rd = cube.GetComponent<Renderer>();
        if (rd != null) rd.material.color = new Color(1f, 0.3f, 0.3f);
        cube.AddComponent<Rotator>().speed = 40f;
        if (Camera.main != null) Camera.main.transform.LookAt(cube.transform);
        Debug.Log("[HTA] Bootstrap OK");
    }
}

public class Rotator : MonoBehaviour
{
    public float speed = 40f;
    void Update()
    {
        transform.Rotate(0f, speed * Time.deltaTime, 0f, Space.World);
    }
}

from shopkit.cli import main


def test_list(capsys):
    assert main(["list"]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 6
    assert lines[0] == "A100\tPlain T-Shirt\t$15.00"


def test_list_tag(capsys):
    assert main(["list", "--tag", "kitchen"]) == 0
    assert [line.split("\t")[0] for line in capsys.readouterr().out.splitlines()] == ["B100", "B200"]

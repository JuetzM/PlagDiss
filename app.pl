#!/usr/bin/env perl
use strict;
use warnings;
use Dancer2;
use LWP::UserAgent;
use XML::LibXML;
use JSON;
use List::Util qw(sum);
use Log::Log4perl qw(:easy);

# --------------------------------------------------
# Logging initialisieren
Log::Log4perl->easy_init($DEBUG);

# --------------------------------------------------
# Konfiguration (wird ggf. auch via ENV-Variablen überschrieben)
my $GPT_API_ENDPOINT = $ENV{'GPT_API_ENDPOINT'} // 'https://chatgpt.com/api/optimize';
my $GPT_API_KEY      = $ENV{'GPT_API_KEY'}      // 'YOUR_API_KEY_HERE';  # API-Key ggf. anpassen

# --------------------------------------------------
# Routen

# Startseite: Formular zur Eingabe des Dissertationstextes
get '/' => sub {
    return qq{
        <html>
        <head>
          <meta charset="UTF-8">
          <title>Dissertationstext prüfen und optimieren</title>
        </head>
        <body>
          <h1>Dissertationstext eingeben</h1>
          <form method="post" action="/process">
            <textarea name="text" rows="20" cols="100" placeholder="Fügen Sie hier Ihren Dissertationstext ein..."></textarea><br><br>
            <input type="submit" value="Text prüfen">
          </form>
        </body>
        </html>
    };
};

# Verarbeitung des eingegebenen Textes
post '/process' => sub {
    my $text = body_parameters->get('text') // '';
    if ($text eq '') {
        error "Kein Text eingegeben!";
        return "Kein Text eingegeben!";
    }
    info "Verarbeite Text mit Länge: " . length($text);

    # 1. Extraktion von PMIDs (Format: "PMID:12345678")
    my @pmids = ($text =~ /PMID[:\s]*([0-9]{5,8})/gi);
    info "Gefundene PMIDs: " . join(", ", @pmids);

    my @results;
    if (@pmids) {
        foreach my $pmid (@pmids) {
            info "Abruf von Artikel für PMID: $pmid";
            my $article = fetch_pubmed_article($pmid);
            if ($article) {
                my $title    = $article->{title}    // 'Kein Titel gefunden';
                my $abstract = $article->{abstract} // 'Kein Abstract vorhanden';
                my $similarity = text_similarity($text, $abstract);
                my $plagiarism_flag = ($similarity > 0.3) 
                    ? "Möglicher Plagiatsverdacht (Similarity: " . sprintf("%.2f", $similarity) . ")"
                    : "OK (Similarity: " . sprintf("%.2f", $similarity) . ")";
                push @results, {
                    pmid       => $pmid,
                    title      => $title,
                    similarity => sprintf("%.2f", $similarity),
                    flag       => $plagiarism_flag,
                };
                info "PMID $pmid: $plagiarism_flag";
            }
            else {
                push @results, {
                    pmid  => $pmid,
                    error => "Datenabruf fehlgeschlagen.",
                };
                warn "Datenabruf für PMID $pmid fehlgeschlagen.";
            }
        }
    }
    else {
        push @results, { message => "Keine PMIDs gefunden. Bitte überprüfen Sie die Referenzierung." };
        info "Keine PMIDs im Text gefunden.";
    }
    
    # Ergebnisse anzeigen und Option zur Textoptimierung anbieten
    my $results_html = "<h2>Ergebnisse der Plagiatsprüfung</h2>";
    foreach my $res (@results) {
        if ($res->{error}) {
            $results_html .= "<p>PMID $res->{pmid}: $res->{error}</p>";
        }
        elsif ($res->{message}) {
            $results_html .= "<p>$res->{message}</p>";
        }
        else {
            $results_html .= qq{
                <div style='border:1px solid #ccc; margin:10px; padding:10px;'>
                    <p><strong>PMID:</strong> $res->{pmid}</p>
                    <p><strong>Titel:</strong> $res->{title}</p>
                    <p><strong>Ähnlichkeitsindex:</strong> $res->{similarity}</p>
                    <p><strong>Status:</strong> $res->{flag}</p>
                </div>
            };
        }
    }
    
    $results_html .= qq{
        <h2>Optional: Text optimieren (via GPT)</h2>
        <form method="post" action="/optimize">
            <input type="hidden" name="text" value="} . encode_entities($text) . qq{">
            <input type="submit" value="Text optimieren">
        </form>
    };
    
    return $results_html;
};

# REST-Endpunkt zur Textoptimierung über GPT
post '/optimize' => sub {
    my $text = body_parameters->get('text') // '';
    if ($text eq '') {
        error "Kein Text für die Optimierung übergeben.";
        return "Kein Text übermittelt!";
    }
    info "Textoptimierung wird durchgeführt.";
    my $optimized_text = optimize_text_with_gpt($text);
    return qq{
        <h2>Optimierter Text (GPT)</h2>
        <pre>$optimized_text</pre>
        <br><a href="/">Zurück</a>
    };
};

# --------------------------------------------------
# Funktionen

# Artikel aus PubMed abrufen (über eFetch) und mittels XML::LibXML parsen
sub fetch_pubmed_article {
    my ($pmid) = @_;
    my $utils = "https://www.ncbi.nlm.nih.gov/entrez/eutils";
    my $url = "$utils/efetch.fcgi?db=pubmed&id=$pmid&retmode=xml";
    my $ua  = LWP::UserAgent->new(timeout => 10);
    my $response = $ua->get($url);
    unless ($response->is_success) {
        warn "HTTP-Anfrage für PMID $pmid schlug fehl: " . $response->status_line;
        return;
    }
    my $xml_content = $response->decoded_content;
    my $parser = XML::LibXML->new();
    my $doc;
    eval { $doc = $parser->parse_string($xml_content); };
    if ($@) {
        warn "XML-Parsing-Fehler für PMID $pmid: $@";
        return;
    }
    my ($article_node) = $doc->findnodes('//PubmedArticle');
    return unless $article_node;
    my $title_node = ($article_node->findnodes('.//ArticleTitle'))[0];
    my $abstract_node = ($article_node->findnodes('.//Abstract/AbstractText'))[0];
    return {
        title    => $title_node    ? $title_node->textContent() : undef,
        abstract => $abstract_node ? $abstract_node->textContent() : undef,
    };
}

# Berechnung der Cosinus-Similarität zwischen zwei Texten (TF-IDF-Ansatz vereinfacht)
sub text_similarity {
    my ($text1, $text2) = @_;
    my $tf1 = term_frequency($text1);
    my $tf2 = term_frequency($text2);
    my $dot = 0;
    foreach my $term (keys %$tf1) {
        $dot += ($tf1->{$term} // 0) * ($tf2->{$term} // 0);
    }
    my $mag1 = sqrt(sum(map { ($_ ** 2) } values %$tf1));
    my $mag2 = sqrt(sum(map { ($_ ** 2) } values %$tf2));
    return ($mag1 * $mag2) ? $dot / ($mag1 * $mag2) : 0;
}

# Berechnet die Termfrequenz (Tokenisierung in Kleinbuchstaben)
sub term_frequency {
    my ($text) = @_;
    my %freq;
    foreach my $word (split /\W+/, lc($text)) {
        next if $word eq '';
        $freq{$word}++;
    }
    return \%freq;
}

# Optimiert den übergebenen Text mittels GPT REST-API
sub optimize_text_with_gpt {
    my ($text) = @_;
    my $ua = LWP::UserAgent->new(timeout => 20);
    my %payload = (
        prompt     => "Bitte optimiere folgenden Dissertationstext hinsichtlich sprachlicher Qualität und wissenschaftlicher Stringenz:\n\n$text",
        max_tokens => 2048,
    );
    my $json_payload = encode_json(\%payload);
    my $req = HTTP::Request->new(POST => $GPT_API_ENDPOINT);
    $req->header('Content-Type'  => 'application/json');
    $req->header('Authorization' => "Bearer $GPT_API_KEY") if $GPT_API_KEY;
    $req->content($json_payload);
    my $res = $ua->request($req);
    if ($res->is_success) {
        my $response_data = decode_json($res->decoded_content);
        return $response_data->{optimized_text} // "Optimierung erfolgreich, aber keine Ausgabe erhalten.";
    }
    else {
        warn "GPT API Anfrage fehlgeschlagen: " . $res->status_line;
        return "Fehler bei der Textoptimierung über GPT.";
    }
}

# Minimaler HTML-Entities Encoder
sub encode_entities {
    my $str = shift // '';
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    return $str;
}

start;

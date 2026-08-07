package benchmark

import (
	"fmt"
	"os"
	"strings"
)

const defaultBenchmarkAddress = ":8080"

type IngestConfig struct {
	Address string
	Brokers []string
	Topic   string
}

type ConsumerConfig struct {
	Address     string
	Brokers     []string
	Topic       string
	GroupID     string
	DatabaseURL string
}

func LoadIngestConfig() (IngestConfig, error) {
	brokers, err := requiredBrokers()
	if err != nil {
		return IngestConfig{}, err
	}
	topic, err := requiredEnvironment("KAFKA_TOPIC")
	if err != nil {
		return IngestConfig{}, err
	}
	return IngestConfig{Address: environmentOrDefault("HTTP_ADDRESS", defaultBenchmarkAddress), Brokers: brokers, Topic: topic}, nil
}

func LoadConsumerConfig() (ConsumerConfig, error) {
	brokers, err := requiredBrokers()
	if err != nil {
		return ConsumerConfig{}, err
	}
	topic, err := requiredEnvironment("KAFKA_TOPIC")
	if err != nil {
		return ConsumerConfig{}, err
	}
	groupID, err := requiredEnvironment("KAFKA_GROUP_ID")
	if err != nil {
		return ConsumerConfig{}, err
	}
	databaseURL, err := requiredEnvironment("DATABASE_URL")
	if err != nil {
		return ConsumerConfig{}, err
	}
	return ConsumerConfig{
		Address:     environmentOrDefault("HTTP_ADDRESS", defaultBenchmarkAddress),
		Brokers:     brokers,
		Topic:       topic,
		GroupID:     groupID,
		DatabaseURL: databaseURL,
	}, nil
}

func requiredBrokers() ([]string, error) {
	rawBrokers, err := requiredEnvironment("KAFKA_BROKERS")
	if err != nil {
		return nil, err
	}
	brokers := strings.Split(rawBrokers, ",")
	for index := range brokers {
		brokers[index] = strings.TrimSpace(brokers[index])
		if brokers[index] == "" {
			return nil, fmt.Errorf("KAFKA_BROKERS contains an empty address")
		}
	}
	return brokers, nil
}

func requiredEnvironment(name string) (string, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return value, nil
}

func environmentOrDefault(name, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}
